package org.octopusden.octopus.quality.internal

import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.api.publish.PublishingExtension
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.publish.maven.tasks.AbstractPublishToMaven
import org.octopusden.octopus.quality.OctopusQualityExtension

/**
 * Registers `verifyCentralPublicationPolicy`, which fails when the set of publications a build
 * would send to Maven Central differs from the set the repository declared.
 *
 * [PublicationValidator] already checks that each publication is *well formed* — POM metadata,
 * sources and javadoc. This checks something different and complementary: that the *set itself*
 * has not drifted. A perfectly well-formed new coordinate passes the former and is caught here.
 *
 * Opt-in, behind an explicit switch. Bumping the plugin never starts failing a repository that
 * has not asked for this:
 *
 * ```
 * octopusQuality {
 *     publication {
 *         enforceCentralPublications.set(true)
 *         centralPublications.set(
 *             setOf(":client|maven|org.example:client|[jar, jar:javadoc, jar:sources]"),
 *         )
 *     }
 * }
 * ```
 *
 * The switch is separate from the set rather than inferred from it, because an EMPTY set is a
 * legitimate declaration — "this repository must publish nothing", which is exactly what a
 * deployable wants. Gradle gives collection properties an empty-collection convention, so an unset
 * property and a deliberately empty one cannot be told apart; inferring intent from emptiness would
 * have silently enforced "publish nothing" on every consumer at the next bump.
 *
 * ### Why the identity is a composite key
 *
 * Each entry is `projectPath|publicationName|groupId:artifactId|[sorted extension:classifier]`.
 * Every part was added because a simpler key silently missed a real change:
 *
 * - **project path alone** cannot tell two publications in the same project apart, and in a
 *   single-module repository the set is `{":"}` no matter what happens;
 * - **without the coordinate**, an overridden `artifactId` or `groupId` goes unnoticed — and a
 *   plugin marker published by `java-gradle-plugin` sits under a *different* group from the
 *   project's own;
 * - **without the artifact signatures**, attaching another classifier to an existing publication
 *   changes nothing. That matters most where a release-time allowlist exempts an artifactId
 *   wholesale: a second oversized artifact under an exempted coordinate would pass every check.
 *
 * The version is deliberately excluded, since every release changes it.
 *
 * ### Why it is wired into `check`
 *
 * Being a dependency of the publish tasks is not enough: no pull-request check runs those, so
 * drift would be merged and surface at the next release instead of in review. It is therefore
 * wired into `check` as well — the same way ktlint and detekt are ordinary gates rather than
 * special cases. It is a task action, never a configuration-time failure, so a violation fails
 * its own gate rather than breaking `build`, `dependencies` and IDE sync.
 */
internal object CentralPublicationPolicy {
    private const val TASK_NAME = "verifyCentralPublicationPolicy"

    /**
     * `publishToSonatype` only exists with the nexus plugin and `publish` is per-project, so these
     * are matched by name rather than forced into existence.
     */
    private val AGGREGATE_PUBLISH_TASKS = setOf("publishToSonatype", "publish", "publishToMavenLocal")

    fun register(
        project: Project,
        rootExtension: OctopusQualityExtension,
    ) {
        val declared = rootExtension.publication.centralPublications
        val enforce = rootExtension.publication.enforceCentralPublications

        val verifyTask =
            project.tasks.register(TASK_NAME) { task ->
                task.group = "verification"
                task.description =
                    "Fails if the set of publications reaching Maven Central drifts from the declared set"

                // Off unless the repository opted in: register the task so it can be invoked and
                // wired, but stay inert. `declared.isPresent` cannot serve here — Gradle gives
                // collection properties an empty-collection convention, so it is true even when
                // nothing was declared, and an empty set is a legitimate declaration in its own right.
                task.onlyIf { enforce.get() }

                task.doLast {
                    val expected = declared.get()
                    val actual = actualPublications(project)
                    if (actual != expected) {
                        throw GradleException(
                            buildString {
                                appendLine("Maven Central publication set drifted.")
                                appendLine("  declared:   ${expected.sorted()}")
                                appendLine("  publishing: ${actual.sorted()}")
                                append(
                                    "Update octopusQuality { publication { centralPublications } } " +
                                        "only if the change is intentional. A coordinate that is not " +
                                        "declared here is also not covered by the release-time " +
                                        "fat-jar-publication-allowlist, so it would either fail the " +
                                        "release or reach Central unnoticed.",
                                )
                            },
                        )
                    }
                }
            }

        // `check` — the gate a pull request actually runs. Matched lazily so plugin application
        // order does not matter, and on every project because `check` is per-project.
        project.allprojects.forEach { candidate ->
            candidate.tasks.matching { it.name == "check" }.configureEach {
                it.dependsOn(verifyTask)
            }
        }

        // The publish path, so a direct `./gradlew publish…` cannot bypass the policy. The task
        // TYPE is hooked as well as the aggregate names: matching names alone leaves every
        // concrete `publish<Pub>PublicationTo<Repo>Repository` task unguarded.
        project.gradle.projectsEvaluated {
            project.allprojects.forEach { candidate ->
                candidate.tasks.withType(AbstractPublishToMaven::class.java).configureEach {
                    it.dependsOn(verifyTask)
                }
                candidate.tasks
                    .matching { it.name in AGGREGATE_PUBLISH_TASKS }
                    .configureEach { it.dependsOn(verifyTask) }
            }
        }
    }

    private fun actualPublications(root: Project): Set<String> =
        root.allprojects
            .filter { it.plugins.hasPlugin("maven-publish") }
            .flatMap { proj ->
                proj.extensions
                    .getByType(PublishingExtension::class.java)
                    .publications
                    .withType(MavenPublication::class.java)
                    .map { pub -> identity(proj, pub) }
            }.toSet()

    private fun identity(
        project: Project,
        publication: MavenPublication,
    ): String {
        val signatures =
            publication.artifacts
                .map { artifact -> listOfNotNull(artifact.extension, artifact.classifier).joinToString(":") }
                .sorted()
        return "${project.path}|${publication.name}|${publication.groupId}:${publication.artifactId}|$signatures"
    }
}
