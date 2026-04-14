package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import org.gradle.api.publish.PublishingExtension
import org.gradle.api.publish.maven.MavenPublication

/**
 * Registers a `validatePublications` task that checks Maven Central readiness:
 * - POM has required fields (name, description, url)
 * - Publication includes sources and javadoc JARs
 *
 * Runs as part of `check` so issues are caught on PR, not at publish time.
 */
internal object PublicationValidator {
    fun register(project: Project) {
        // Only for projects that have maven-publish applied
        project.plugins.withId("maven-publish") {
            project.tasks.register("validatePublications") { task ->
                task.group = "verification"
                task.description =
                    "Validates that Maven publications meet Central Portal requirements"
                task.doLast {
                    val publishing =
                        project.extensions.getByType(PublishingExtension::class.java)
                    val publications =
                        publishing.publications.withType(MavenPublication::class.java)

                    if (publications.isEmpty()) {
                        project.logger.warn(
                            "validatePublications: no MavenPublication found in ${project.path}",
                        )
                        return@doLast
                    }

                    val errors = mutableListOf<String>()

                    for (pub in publications) {
                        val prefix = "${project.path}:${pub.name}"

                        if (pub.pom.name.orNull
                                .isNullOrBlank()
                        ) {
                            errors.add("$prefix: POM <name> is missing or blank")
                        }
                        if (pub.pom.description.orNull
                                .isNullOrBlank()
                        ) {
                            errors.add("$prefix: POM <description> is missing or blank")
                        }
                        if (pub.pom.url.orNull
                                .isNullOrBlank()
                        ) {
                            errors.add("$prefix: POM <url> is missing or blank")
                        }

                        val classifiers = pub.artifacts.map { it.classifier }.toSet()
                        if ("sources" !in classifiers) {
                            errors.add(
                                "$prefix: sources JAR missing (Maven Central requires it)",
                            )
                        }
                        if ("javadoc" !in classifiers) {
                            errors.add(
                                "$prefix: javadoc JAR missing (Maven Central requires it)",
                            )
                        }
                    }

                    if (errors.isNotEmpty()) {
                        val message =
                            buildString {
                                appendLine("Maven Central publication validation failed:")
                                errors.forEach { appendLine("  - $it") }
                                appendLine()
                                appendLine(
                                    "Fix these before publishing. " +
                                        "See https://central.sonatype.org/publish/requirements/",
                                )
                            }
                        throw org.gradle.api.GradleException(message)
                    }

                    project.logger.lifecycle(
                        "validatePublications: ${publications.size} publication(s) " +
                            "in ${project.path} passed Maven Central checks",
                    )
                }
            }

            // Wire into check so it runs on every PR build
            project.tasks.named("check") { it.dependsOn("validatePublications") }
        }
    }
}
