@file:DependsOn("org.danilopianini:khttp:1.2.0")

import khttp.get
import khttp.post
import org.json.JSONObject
import java.util.concurrent.TimeUnit

// Triggers a GitHub release (repository_dispatch) and watches the resulting
// workflow run. Fails FAST with an actionable TeamCity build problem when the
// run concludes in failure — instead of blindly polling the release tag until a
// bare timeout — and links to the run, where the reusable workflow's
// "Diagnose & classify" step reports the cause and RELEASE_PUBLISH_RETRYABLE.
// Arguments are unchanged for backward compatibility.

if (args.size != 6) {
    System.err.println("Arguments: octopusModule githubToken currentCommit versionToRelease timeoutInMinutes eventType")
    System.exit(-1)
}

val octopusModule = args[0]
val githubToken = args[1]
val currentCommit = args[2]
val versionToRelease = args[3]
val timeoutMinutes = Integer.valueOf(args[4])
val eventType = args[5]

val repo = "octopusden/$octopusModule"
val api = "https://api.github.com/repos/$repo"
val ghHeaders = mapOf(
    "Authorization" to "Bearer $githubToken",
    "Accept" to "application/vnd.github+json"
)

// Emit a TeamCity build problem (escaped per TeamCity service-message rules).
fun buildProblem(description: String) {
    val escaped = description
        .replace("|", "||").replace("'", "|'")
        .replace("\n", "|n").replace("\r", "|r")
        .replace("[", "|[").replace("]", "|]")
    println("##teamcity[buildProblem description='$escaped' identity='github-release']")
}

fun fail(description: String): Nothing {
    buildProblem(description)
    System.err.println(description)
    System.exit(3)
    throw IllegalStateException() // unreachable; satisfies Nothing
}

// 1) Trigger the release.
val respCreate = post(
    "$api/dispatches",
    headers = ghHeaders,
    data = """{"event_type":"$eventType","client_payload":{"commit":"$currentCommit","project_version":"$versionToRelease"}}"""
)
if (respCreate.statusCode / 100 != 2) {
    fail("Failed to trigger release dispatch for $repo (HTTP ${respCreate.statusCode}): ${respCreate.text}")
}
println("Release dispatched for $repo version $versionToRelease. Watching the workflow run...")

// 2) Watch the triggered workflow run: lock onto the newest repository_dispatch
//    run (releases are serial), then poll its conclusion. Fail fast on failure.
var runId: Long? = null
var runUrl: String? = null
var attempt = 0
while (true) {
    attempt++
    if (attempt > timeoutMinutes) {
        val seen = runUrl?.let { " Last observed run: $it" } ?: " No matching run was observed."
        fail("Release for $repo $versionToRelease did not complete within $timeoutMinutes minute(s).$seen")
    }
    TimeUnit.MINUTES.sleep(1L)

    if (runId == null) {
        val runs = get("$api/actions/runs?event=repository_dispatch&per_page=10", headers = ghHeaders)
        if (runs.statusCode / 100 == 2) {
            val arr = runs.jsonObject.optJSONArray("workflow_runs")
            if (arr != null && arr.length() > 0) {
                val chosen = arr.getJSONObject(0) // newest first
                runId = chosen.getLong("id")
                runUrl = chosen.optString("html_url")
                println("Watching run: $runUrl")
            } else {
                println("Attempt $attempt: no repository_dispatch run visible yet...")
            }
        } else {
            println("Attempt $attempt: could not list runs (HTTP ${runs.statusCode}); retrying...")
        }
        continue
    }

    val run: JSONObject = get("$api/actions/runs/$runId", headers = ghHeaders).jsonObject
    val status = run.optString("status")
    val conclusion = run.optString("conclusion")
    println("Attempt $attempt: run status=$status conclusion=$conclusion")
    if (status == "completed") {
        if (conclusion == "success") {
            println("Release run succeeded: $runUrl")
            System.exit(0)
        }
        fail(
            "Release run for $repo $versionToRelease concluded '$conclusion'. See $runUrl " +
            "(open the 'Diagnose & classify Sonatype publish failure' step for the cause and " +
            "RELEASE_PUBLISH_RETRYABLE: deterministic => do not re-dispatch; transient => a re-dispatch may help)."
        )
    }
}
