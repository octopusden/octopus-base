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

// List current repository_dispatch run IDs. Returns (ok, ids): ok=false means the
// listing call itself failed (so the snapshot is unreliable).
fun listDispatchRunIds(): Pair<Boolean, Set<Long>> {
    val resp = get("$api/actions/runs?event=repository_dispatch&per_page=50", headers = ghHeaders)
    if (resp.statusCode / 100 != 2) return Pair(false, emptySet())
    val arr = resp.jsonObject.optJSONArray("workflow_runs") ?: return Pair(true, emptySet())
    val ids = HashSet<Long>()
    for (i in 0 until arr.length()) ids.add(arr.getJSONObject(i).getLong("id"))
    return Pair(true, ids)
}

// Snapshot existing runs BEFORE dispatching so we only ever lock onto a NEW run
// afterwards — never a prior release's (possibly failed) run.
val (preOk, preExisting) = listDispatchRunIds()
if (!preOk) println("Warning: could not snapshot existing runs before dispatch; new-run detection is best-effort.")

// 1) Trigger the release.
val respCreate = post(
    "$api/dispatches",
    headers = ghHeaders,
    data = """{"event_type":"$eventType","client_payload":{"commit":"$currentCommit","project_version":"$versionToRelease"}}"""
)
if (respCreate.statusCode / 100 != 2) {
    fail("Failed to trigger release dispatch for $repo (HTTP ${respCreate.statusCode}): ${respCreate.text}")
}
println("Release dispatched for $repo version $versionToRelease. Watching for the new workflow run...")

// 2) Watch the run triggered by THIS dispatch: pick the newest repository_dispatch
//    run whose id was not present before the dispatch, then poll its conclusion and
//    fail fast on failure. (repository_dispatch client_payload is not exposed in the
//    runs API, so a "new id not seen before" match is used; concurrent dispatches of
//    the same repo are not disambiguated — releases are expected to be serial.)
var runId: Long? = null
var runUrl: String? = null
var attempt = 0
while (true) {
    attempt++
    if (attempt > timeoutMinutes) {
        val seen = runUrl?.let { " Last observed run: $it" } ?: " No new workflow run appeared."
        fail("Release for $repo $versionToRelease did not complete within $timeoutMinutes minute(s).$seen")
    }
    TimeUnit.MINUTES.sleep(1L)

    if (runId == null) {
        val runs = get("$api/actions/runs?event=repository_dispatch&per_page=50", headers = ghHeaders)
        if (runs.statusCode / 100 != 2) {
            println("Attempt $attempt: could not list runs (HTTP ${runs.statusCode}); retrying...")
            continue
        }
        val arr = runs.jsonObject.optJSONArray("workflow_runs")
        var chosen: JSONObject? = null
        if (arr != null) {
            for (i in 0 until arr.length()) { // newest first
                val r = arr.getJSONObject(i)
                if (!preExisting.contains(r.getLong("id"))) { chosen = r; break }
            }
        }
        if (chosen == null) {
            println("Attempt $attempt: new release run not visible yet...")
            continue
        }
        runId = chosen.getLong("id")
        runUrl = chosen.optString("html_url")
        println("Watching new run: $runUrl")
        continue
    }

    val runResp = get("$api/actions/runs/$runId", headers = ghHeaders)
    if (runResp.statusCode / 100 != 2) {
        println("Attempt $attempt: could not read run $runId (HTTP ${runResp.statusCode}); retrying...")
        continue
    }
    val run: JSONObject = runResp.jsonObject
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
