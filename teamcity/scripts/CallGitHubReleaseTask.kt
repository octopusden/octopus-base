@file:DependsOn("khttp:khttp:1.0.0")

import khttp.get
import khttp.post
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

val respCreate = post("https://api.github.com/repos/octopusden/${args[0]}/dispatches", mapOf("Authorization" to "Bearer ${args[1]}"), emptyMap(), """{
        "event_type": "${args[5]}",
        "client_payload": {
        "commit": "${args[2]}",
        "project_version": "${args[3]}"
    }""")
if (respCreate.statusCode / 100 != 2) {
    throw Exception(respCreate.text)
}
println("Waiting for release to complete...")
var attempt = 1
var limit = Integer.valueOf(args[4])
do {
	   println("Attempt: " + attempt)
     if (attempt > limit) {
         throw TimeoutException("Number of attempts exceeded($attempt)")
     }
     TimeUnit.MINUTES.sleep(1L)
     val respCheck = get(url = "https://api.github.com/repos/octopusden/${args[0]}/releases/tags/v${args[3]}")
	   attempt++
} while (respCheck.statusCode / 100 != 2)
