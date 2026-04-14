plugins {
    `java-gradle-plugin`
    `maven-publish`
    signing
    id("org.jetbrains.kotlin.jvm") version "2.2.0"
    // detekt/ktlint versions come from settings.gradle.kts pluginManagement
    // (single source of truth with the compileOnly dependency versions below)
    id("io.gitlab.arturbosch.detekt")
    id("org.jlleitschuh.gradle.ktlint")
    id("io.github.gradle-nexus.publish-plugin") version "2.0.0"
}

val detektVersion: String by project
val ktlintGradleVersion: String by project
val koverVersion: String by project
val spotbugsGradleVersion: String by project

repositories {
    mavenCentral()
    gradlePluginPortal()
}

// External quality plugins: compileOnly for production (consumer provides versions),
// but TestKit needs them on the plugin classpath to load our classes that reference them.
val externalPlugins by configurations.creating

dependencies {
    compileOnly("io.gitlab.arturbosch.detekt:detekt-gradle-plugin:$detektVersion")
    compileOnly("org.jlleitschuh.gradle:ktlint-gradle:$ktlintGradleVersion")
    compileOnly("org.jetbrains.kotlinx:kover-gradle-plugin:$koverVersion")
    compileOnly("org.jetbrains.kotlin:kotlin-gradle-plugin:${property("kotlinGradlePluginVersion")}")
    // SpotBugs has no Kotlin version coupling — safe to bundle.
    implementation("com.github.spotbugs.snom:spotbugs-gradle-plugin:$spotbugsGradleVersion")

    // Same deps for TestKit classpath (not published, only for tests)
    externalPlugins("io.gitlab.arturbosch.detekt:detekt-gradle-plugin:$detektVersion")
    externalPlugins("org.jlleitschuh.gradle:ktlint-gradle:$ktlintGradleVersion")
    externalPlugins("org.jetbrains.kotlinx:kover-gradle-plugin:$koverVersion")
    externalPlugins("org.jetbrains.kotlin:kotlin-gradle-plugin:${property("kotlinGradlePluginVersion")}")

    testImplementation(gradleTestKit())
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

// Inject external plugin JARs into TestKit's plugin classpath
tasks.named("pluginUnderTestMetadata") {
    (this as org.gradle.plugin.devel.tasks.PluginUnderTestMetadata)
        .pluginClasspath
        .from(externalPlugins)
}

tasks.withType<Test> {
    useJUnitPlatform()
}

java {
    withJavadocJar()
    withSourcesJar()
}

kotlin {
    // JDK 11 = minimum CI runtime across all target repos.
    // Gradle 8.x requires JDK 11+, quality tools (Checkstyle 10.x) require JDK 11+.
    // Repos with bytecode target 1.8 (octopus-rm-gradle-plugin, octopus-license-gradle-plugin)
    // run CI on JDK 11+ — only bytecode target stays 1.8, not the build JVM.
    jvmToolchain(11)
}

detekt {
    buildUponDefaultConfig = true
    allRules = false
    config.setFrom(file("src/main/resources/org/octopusden/octopus/quality/config/detekt.yml"))
}

ktlint {
    outputToConsole.set(true)
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

if (project.hasProperty("nexus")) {
    nexusPublishing {
        repositories {
            sonatype {
                nexusUrl.set(uri("https://ossrh-staging-api.central.sonatype.com/service/local/"))
                snapshotRepositoryUrl.set(uri("https://central.sonatype.com/repository/maven-snapshots/"))
                username.set(System.getenv("MAVEN_USERNAME"))
                password.set(System.getenv("MAVEN_PASSWORD"))
            }
        }
    }
}

publishing {
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
    isRequired = gradle.startParameter.taskNames.any { it == "publishToSonatype" || it.endsWith(":publishToSonatype") }
}
