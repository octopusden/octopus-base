@file:DependsOn("org.apache.maven:maven-artifact:3.9.3")

import org.apache.maven.artifact.versioning.ComparableVersion

println("Hello World!")

val version1 = ComparableVersion("1.2.3")
val version2 = ComparableVersion("1.3.4")

println(version1)
println(version2)

println(version1.compareTo(version2))
