@file:DependsOn("org.danilopianini:khttp:1.2.0")

import khttp.get
import khttp.post
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

if (args.size != 6) {
    System.err.println("Arguments: octopusModule githubToken currentCommit versionToRelease timeoutInMinutes eventType")
    System.exit(-1)
}

val octopusModule = args[0]
val githubToken = args[1]
val currentCommit = args[2]
val versionToRelease = args[3]
val timeoutMinutes = args[4]
val eventType = args[5]

val respCreate = post("https://api.github.com/repos/octopusden/$octopusModule/dispatches", mapOf("Authorization" to "Bearer $githubToken"), emptyMap(), """{
        "event_type": "$eventType",
        "client_payload": {
        "commit": "$currentCommit",
        "project_version": "$versionToRelease"
    }""")
if (respCreate.statusCode / 100 != 2) {
    throw Exception(respCreate.text)
}
println("Waiting for release to complete...")
var attempt = 1
var limit = Integer.valueOf(timeoutMinutes)
do {
    println("Attempt: " + attempt)
    if (attempt > limit) {
        throw TimeoutException("Number of attempts exceeded($attempt)")
    }
    TimeUnit.MINUTES.sleep(1L)
    val respCheck = get(url = "https://api.github.com/repos/octopusden/$octopusModule/releases/tags/v$versionToRelease")
    attempt++
} while (respCheck.statusCode / 100 != 2)
