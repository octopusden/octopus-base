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

        /** Enable coverage verification. Set to false for repos without tests. */
        val enabled = objects.property(Boolean::class.java).convention(true)

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
