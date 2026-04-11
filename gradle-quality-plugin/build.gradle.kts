plugins {
    `java-gradle-plugin`
    `maven-publish`
    signing
    id("org.jetbrains.kotlin.jvm") version "2.2.0"
}

val detektVersion: String by project
val ktlintGradleVersion: String by project
val koverVersion: String by project
val spotbugsGradleVersion: String by project

repositories {
    mavenCentral()
    gradlePluginPortal()
}

dependencies {
    implementation("io.gitlab.arturbosch.detekt:detekt-gradle-plugin:$detektVersion")
    implementation("org.jlleitschuh.gradle:ktlint-gradle:$ktlintGradleVersion")
    implementation("org.jetbrains.kotlinx:kover-gradle-plugin:$koverVersion")
    implementation("com.github.spotbugs.snom:spotbugs-gradle-plugin:$spotbugsGradleVersion")
    // Detekt/KtLint need Kotlin Gradle plugin classes at runtime when applied to Kotlin subprojects.
    // Detekt declares this as compileOnly, so we must bring it explicitly.
    implementation("org.jetbrains.kotlin:kotlin-gradle-plugin:${property("kotlinGradlePluginVersion")}")
}

kotlin {
    jvmToolchain(17)
}

gradlePlugin {
    plugins {
        create("octopusQuality") {
            id = "org.octopusden.octopus-quality"
            implementationClass = "org.octopusden.octopus.quality.OctopusQualityPlugin"
            displayName = "Octopus JVM Quality Gates"
            description = "Convention plugin providing unified quality gates (linters, coverage, security) for octopusden JVM repositories"
        }
    }
}

publishing {
    repositories {
        maven {
            name = "sonatype"
            url = uri("https://ossrh-staging-api.central.sonatype.com/service/local/")
            credentials {
                username = System.getenv("MAVEN_USERNAME")
                password = System.getenv("MAVEN_PASSWORD")
            }
        }
    }
    publications.withType<MavenPublication> {
        pom {
            name.set("Octopus JVM Quality Gates Plugin")
            description.set("Convention plugin for unified quality gates across octopusden JVM repositories")
            url.set("https://github.com/octopusden/octopus-base")
            licenses {
                license {
                    name.set("The Apache License, Version 2.0")
                    url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                }
            }
            scm {
                url.set("https://github.com/octopusden/octopus-base")
                connection.set("scm:git://github.com/octopusden/octopus-base.git")
            }
            developers {
                developer {
                    id.set("octopus")
                    name.set("octopus")
                }
            }
        }
    }
}

signing {
    val signingKey: String? by project
    val signingPassword: String? by project
    useInMemoryPgpKeys(signingKey, signingPassword)
    sign(publishing.publications)
    isRequired = gradle.taskGraph.hasTask("publishToSonatype")
}
