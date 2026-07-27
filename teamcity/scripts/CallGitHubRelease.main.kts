@file:DependsOn("org.json:json:20231013")

import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
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
val timeoutMinutes = args[4].toIntOrNull() ?: -1
if (timeoutMinutes < 0) {
    System.err.println("timeoutInMinutes must be a non-negative integer, got: ${args[4]}")
    System.exit(-1)
}
val eventType = args[5]

// Both values are interpolated into request URLs. Rejecting anything that would
// need escaping here means URI building cannot fail later, so the request path has
// to handle transport errors only.
for ((name, value) in listOf("octopusModule" to octopusModule, "versionToRelease" to versionToRelease)) {
    if (!Regex("^[A-Za-z0-9][A-Za-z0-9._+-]*$").matches(value)) {
        System.err.println("$name contains characters that cannot appear in a request URL: '$value'")
        System.exit(-1)
    }
}

val repo = "octopusden/$octopusModule"
val api = "https://api.github.com/repos/$repo"

class Response(val statusCode: Int, val text: String) {
    // Null when the body is empty or not JSON: a 2xx is no guarantee of JSON (a proxy
    // or WAF interstitial can answer 200 with HTML), and an uncaught JSONException
    // would replace the actionable build problem with a stack trace. Callers treat
    // null as a failed read and retry.
    fun json(): JSONObject? = try {
        if (text.isBlank()) null else JSONObject(text)
    } catch (e: Exception) {
        null
    }
}

// Minimal GitHub client on java.net.HttpURLConnection, which every JDK supports.
// A transport failure is reported as status 0 so callers retry through their normal
// non-2xx path instead of the script dying with a stack trace. Only IOException is
// caught: anything else is a defect in this script and should surface as one.
fun request(method: String, url: String, body: String? = null): Response {
    var connection: HttpURLConnection? = null
    return try {
        // URI().toURL() rather than URL(String): the latter is deprecated on JDK 20+
        // and would print a warning on every release build.
        val opened = URI(url).toURL().openConnection() as HttpURLConnection
        connection = opened
        opened.requestMethod = method
        opened.connectTimeout = 15000
        opened.readTimeout = 30000
        opened.setRequestProperty("Authorization", "Bearer $githubToken")
        opened.setRequestProperty("Accept", "application/vnd.github+json")
        opened.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
        opened.setRequestProperty("User-Agent", "octopus-teamcity-release-poller")
        if (body != null) {
            opened.setRequestProperty("Content-Type", "application/json")
            opened.doOutput = true
            opened.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }
        val code = opened.responseCode
        val stream = if (code >= 400) opened.errorStream else opened.inputStream
        val text = stream?.use { BufferedReader(InputStreamReader(it, Charsets.UTF_8)).readText() } ?: ""
        Response(code, text)
    } catch (e: IOException) {
        Response(0, "transport error: ${e.javaClass.simpleName}: ${e.message}")
    } finally {
        connection?.disconnect()
    }
}

fun get(url: String): Response = request("GET", url)

fun post(url: String, body: String): Response = request("POST", url, body)

// Status 0 means the request never got an HTTP answer, so the status alone says
// nothing. Without this an agent with broken DNS or a blocked proxy would print
// "HTTP 0" once a minute for the whole timeout with no hint of the cause.
fun Response.why(): String = if (statusCode == 0) " — $text" else ""

// Emit a TeamCity build problem (escaped per TeamCity service-message rules).
fun buildProblem(description: String) {
    val escaped = description
        .replace("|", "||").replace("'", "|'")
        .replace("\n", "|n").replace("\r", "|r")
        .replace("[", "|[").replace("]", "|]")
    println("##teamcity[buildProblem description='$escaped' identity='github-release-$octopusModule']")
}

fun fail(description: String): Nothing {
    buildProblem(description)
    System.err.println(description)
    System.exit(3)
    throw IllegalStateException() // unreachable; satisfies Nothing
}

// List current repository_dispatch run IDs. Returns (ok, ids, reason): ok=false
// means the listing call itself failed (so the snapshot is unreliable), and reason
// carries what went wrong for the log.
fun listDispatchRunIds(): Triple<Boolean, Set<Long>, String> {
    val resp = get("$api/actions/runs?event=repository_dispatch&per_page=50")
    if (resp.statusCode / 100 != 2) return Triple(false, emptySet(), "HTTP ${resp.statusCode}${resp.why()}")
    val body = resp.json()
        ?: return Triple(false, emptySet(), "HTTP ${resp.statusCode} with an empty or non-JSON body")
    // An empty workflow_runs array is legitimate (no dispatch has ever run here); a
    // missing one is not, and treating it as "no previous runs" is exactly what lets
    // a historical run later be mistaken for the one this script triggered.
    val arr = body.optJSONArray("workflow_runs")
        ?: return Triple(false, emptySet(), "HTTP ${resp.statusCode} with no workflow_runs array")
    val ids = HashSet<Long>()
    for (i in 0 until arr.length()) ids.add(arr.getJSONObject(i).getLong("id"))
    return Triple(true, ids, "")
}

// Snapshot existing runs BEFORE dispatching so we only ever lock onto a NEW run
// afterwards — never a prior release's (possibly failed) run. A reliable baseline is
// mandatory: retry, and ABORT BEFORE dispatch if it can't be obtained (dispatching
// blind could make us mistake a historical run for this release).
var preExistingTmp: Set<Long>? = null
for (i in 1..3) {
    val (ok, ids, reason) = listDispatchRunIds()
    if (ok) { preExistingTmp = ids; break }
    println("Could not snapshot existing runs (attempt $i/3): $reason; retrying...")
    TimeUnit.SECONDS.sleep(5L)
}
val preExisting: Set<Long> = preExistingTmp
    ?: fail("Could not snapshot existing workflow runs before dispatching (GitHub API unavailable). Aborting before dispatch to avoid mis-tracking a prior run; please retry the release.")

// 1) Trigger the release. Build the body with org.json so special characters in
//    the arguments can't break the JSON.
val dispatchBody = JSONObject()
    .put("event_type", eventType)
    .put("client_payload", JSONObject().put("commit", currentCommit).put("project_version", versionToRelease))
    .toString()
val respCreate = post("$api/dispatches", dispatchBody)
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
        val runs = get("$api/actions/runs?event=repository_dispatch&per_page=50")
        if (runs.statusCode / 100 != 2) {
            println("Attempt $attempt: could not list runs (HTTP ${runs.statusCode}${runs.why()}); retrying...")
            continue
        }
        val runsBody = runs.json()
        if (runsBody == null) {
            println("Attempt $attempt: run listing returned an empty or non-JSON body; retrying...")
            continue
        }
        val arr = runsBody.optJSONArray("workflow_runs")
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
        // !! is safe: the null-check above `continue`s when chosen is null. A plain
        // smart-cast doesn't compile here — in a .main.kts the script body is a
        // closure, so the captured `var chosen` cannot be smart-cast.
        runId = chosen!!.getLong("id")
        runUrl = chosen!!.optString("html_url")
        println("Watching new run: $runUrl")
        continue
    }

    val runResp = get("$api/actions/runs/$runId")
    if (runResp.statusCode / 100 != 2) {
        println("Attempt $attempt: could not read run $runId (HTTP ${runResp.statusCode}${runResp.why()}); retrying...")
        continue
    }
    val run = runResp.json()
    if (run == null) {
        println("Attempt $attempt: run $runId returned an empty or non-JSON body; retrying...")
        continue
    }
    val status = run.optString("status")
    val conclusion = run.optString("conclusion")
    println("Attempt $attempt: run status=$status conclusion=$conclusion")
    if (status == "completed") {
        if (conclusion == "success") {
            println("Release run succeeded: $runUrl")
            // Belt-and-braces: confirm the release tag exists, retrying within the
            // remaining time budget so one transient tag GET (404 propagation delay /
            // 5xx) doesn't turn a real success into a false failure.
            while (true) {
                val tag = get("$api/releases/tags/v$versionToRelease")
                if (tag.statusCode / 100 == 2) {
                    println("Release tag v$versionToRelease is present.")
                    System.exit(0)
                }
                attempt++
                if (attempt > timeoutMinutes) {
                    fail("Release run for $repo succeeded but release tag v$versionToRelease was not confirmed within the timeout (last HTTP ${tag.statusCode}). See $runUrl")
                }
                println("Tag v$versionToRelease not confirmed yet (HTTP ${tag.statusCode}${tag.why()}); retrying...")
                TimeUnit.MINUTES.sleep(1L)
            }
        } else {
            fail(
                "Release run for $repo $versionToRelease concluded '$conclusion'. See $runUrl " +
                "(open the 'Diagnose & classify Sonatype publish failure' step for the cause and " +
                "RELEASE_PUBLISH_RETRYABLE: deterministic => do not re-dispatch; transient => a re-dispatch may help)."
            )
        }
    }
}
