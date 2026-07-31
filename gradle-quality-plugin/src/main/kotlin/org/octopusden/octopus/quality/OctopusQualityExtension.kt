package org.octopusden.octopus.quality

import org.gradle.api.Action
import org.gradle.api.model.ObjectFactory
import org.gradle.api.provider.SetProperty
import javax.inject.Inject

open class OctopusQualityExtension
    @Inject
    constructor(
        objects: ObjectFactory,
    ) {
        val coverage: CoverageExtension = objects.newInstance(CoverageExtension::class.java)
        val publication: PublicationExtension = objects.newInstance(PublicationExtension::class.java)
        val kotlin: KotlinExtension = objects.newInstance(KotlinExtension::class.java)
        val java: JavaExtension = objects.newInstance(JavaExtension::class.java)
        val groovy: GroovyExtension = objects.newInstance(GroovyExtension::class.java)

        /** Subproject names to exclude from coverage verification (qualityCoverage). */
        val coverageExcludedProjects: SetProperty<String> = objects.setProperty(String::class.java).convention(emptySet())

        /**
         * Task names to exclude from the aggregate quality-gate task dependencies.
         *
         * Applies ONLY to the `qualityStatic` / `qualityCoverage` aggregate tasks (and, transitively,
         * `qualityCheck`) — it prunes which analysis/coverage tasks those aggregates depend on.
         * It does NOT touch the standard `check` → `test` task graph: an excluded `test` still runs
         * under `check`, it is simply not pulled in by `qualityCoverage`.
         */
        val excludedTasks: SetProperty<String> = objects.setProperty(String::class.java).convention(emptySet())

        fun coverage(action: Action<CoverageExtension>) = action.execute(coverage)

        fun publication(action: Action<PublicationExtension>) = action.execute(publication)

        fun kotlin(action: Action<KotlinExtension>) = action.execute(kotlin)

        fun java(action: Action<JavaExtension>) = action.execute(java)

        fun groovy(action: Action<GroovyExtension>) = action.execute(groovy)

        fun excludeTasks(vararg tasks: String) {
            excludedTasks.addAll(*tasks)
        }

        fun excludeProjects(vararg projects: String) {
            coverageExcludedProjects.addAll(*projects)
        }
    }

open class CoverageExtension
    @Inject
    constructor(
        objects: ObjectFactory,
    ) {
        enum class Tool { AUTO, JACOCO, KOVER }

        /**
         * Enable coverage. Governs BOTH the coverage report and verification on `check`/`build`:
         * when `false`, neither the report nor the verify task runs on `check` and no coverage rule is
         * configured (for Kover and JaCoCo alike); when `true` (default) the report runs on `check` while
         * floor enforcement is gated by [verifyInCheck] (or the `qualityCoverage` aggregate).
         * Set to `false` for repos without tests.
         */
        val enabled = objects.property(Boolean::class.java).convention(true)

        /**
         * Enforce the per-module line-coverage floor on `check`/`build`.
         *
         * Default `false`: with coverage `enabled` (the default) the report still runs on `check`,
         * but the floor is NOT enforced there — enforce it via the `qualityCoverage` aggregate task.
         * Set to `true` to additionally gate `check` on `koverVerify` / `jacocoTestCoverageVerification`.
         * Has no effect when `enabled` is `false` (no report and no verify run on `check`).
         */
        val verifyInCheck = objects.property(Boolean::class.java).convention(false)

        /** Coverage tool selection. AUTO detects based on project languages. */
        val tool = objects.property(Tool::class.java).convention(Tool.AUTO)

        /** Minimum line coverage per module (default 10%). */
        val minimumLineCoverage =
            objects
                .property(java.math.BigDecimal::class.java)
                .convention(java.math.BigDecimal("0.10"))

        /** Minimum overall aggregated line coverage (default 70%). */
        val overallMinimum =
            objects
                .property(java.math.BigDecimal::class.java)
                .convention(java.math.BigDecimal("0.70"))
    }

open class PublicationExtension
    @Inject
    constructor(
        objects: ObjectFactory,
    ) {
        /**
         * Enforce Maven Central readiness (`validatePublications` wired into `check`) for every
         * `maven-publish` project. Set to false for repos that are not published to Maven Central,
         * so `check` does not require sources/javadoc JARs and full POM metadata.
         *
         * Root-level / per-repo / all-or-nothing by design.
         */
        val validateForMavenCentral = objects.property(Boolean::class.java).convention(true)

        /**
         * The exact set of publications this repository is allowed to send to Maven Central.
         *
         * Opt-in: leave it unset and nothing is enforced. Setting it — including to an EMPTY set,
         * which means "this repository must publish nothing" — turns on `verifyCentralPublicationPolicy`,
         * wired into `check` so drift is caught in review rather than at the next release.
         *
         * Each entry identifies one publication as
         * `projectPath|publicationName|groupId:artifactId|[sorted extension:classifier]`, for example
         * `":client|maven|org.example:client|[jar, jar:javadoc, jar:sources]"`.
         *
         * The composite shape is not decoration. A project path alone cannot distinguish two
         * publications in the same project, and is constant in a single-module build; without the
         * coordinate an overridden artifactId or a plugin marker under a different group goes
         * unnoticed; without the artifact signatures, attaching another classifier to an existing
         * publication changes nothing. The version is excluded on purpose — every release changes it.
         *
         * The easiest way to obtain the values is to enable enforcement with an empty set once and
         * run the task: the failure message prints the actual set, which can be pasted back.
         */
        val centralPublications: SetProperty<String> =
            objects.setProperty(String::class.java).convention(emptySet())

        /**
         * Turn the publication-set check on. Off by default, so bumping the plugin never starts
         * failing a repository that has not opted in.
         *
         * This is a separate switch rather than "enforce when the set is non-empty", because an
         * EMPTY set is itself a meaningful declaration — "this repository must publish nothing" —
         * and that is exactly the case worth guarding in a deployable. Gradle gives collection
         * properties an empty-collection convention, so an unset property and a deliberately empty
         * one are indistinguishable without this flag.
         */
        val enforceCentralPublications = objects.property(Boolean::class.java).convention(false)
    }

open class KotlinExtension
    @Inject
    constructor(
        objects: ObjectFactory,
    ) {
        /** Whether Kotlin tools (detekt, ktlint) fail the build on violations. */
        val failOnViolation = objects.property(Boolean::class.java).convention(false)
    }

open class JavaExtension
    @Inject
    constructor(
        objects: ObjectFactory,
    ) {
        /** Whether Java tools (checkstyle, pmd, spotbugs) fail the build on violations. */
        val failOnViolation = objects.property(Boolean::class.java).convention(false)
    }

open class GroovyExtension
    @Inject
    constructor(
        objects: ObjectFactory,
    ) {
        /** Whether Groovy tools (codenarc) fail the build on violations. */
        val failOnViolation = objects.property(Boolean::class.java).convention(false)
    }
