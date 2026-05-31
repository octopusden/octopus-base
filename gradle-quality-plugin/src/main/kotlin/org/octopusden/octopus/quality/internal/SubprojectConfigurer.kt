package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import org.octopusden.octopus.quality.CoverageExtension
import org.octopusden.octopus.quality.OctopusQualityExtension
import java.io.File

/**
 * Configures quality tool plugins on individual subprojects (or root if single-module)
 * based on detected languages.
 */
@Suppress("TooManyFunctions") // One configurer per supported tool — splitting would just relocate the count.
internal object SubprojectConfigurer {
    /**
     * Phase 1 — synchronous, runs during root script evaluation (before any subproject
     * `afterEvaluate`). Registers `plugins.withId(...)` callbacks for tools whose tasks
     * read settings during their own configuration (ktlint, detekt). Settings made here
     * land before the upstream tool wires its tasks, so things like baselines actually
     * take effect on the first build.
     *
     * Inside the registered callbacks, NEVER call `.get()` on consumer-extension
     * properties — the consumer's `octopusQuality { ... }` block may not have been
     * processed yet. Use lazy `Provider` wiring (`.map { ... }`) instead, or defer the
     * setting to the afterEvaluate path (see `configureDetektFailureFlag`).
     */
    fun registerEarly(
        project: Project,
        rootProject: Project,
        extension: OctopusQualityExtension,
    ) {
        val configDir = resolveConfigDir(rootProject)
        project.plugins.withId("org.jlleitschuh.gradle.ktlint") {
            configureKtlint(project, configDir, extension)
        }
        project.plugins.withId("io.gitlab.arturbosch.detekt") {
            configureDetektEarly(project, configDir)
        }
    }

    fun configure(
        project: Project,
        rootProject: Project,
        extension: OctopusQualityExtension,
    ) {
        val configDir = resolveConfigDir(rootProject)
        val languages = LanguageDetector.detect(project)

        // Checkstyle/PMD analyse Java *source* — harmless no-ops on modules without `.java`,
        // so keep them broadly applied. SpotBugs analyses *bytecode* and scans the module's
        // whole compiled output: when Kotlin is present it reads the Kotlin classes too and
        // produces ~95% false positives (lateinit / DSL getters / synthetic accessors). Gate it
        // to modules that have Java and NO Kotlin (Java-only or Java+Groovy qualify — only Kotlin
        // triggers the false-positive flood). Java 25 / class file v69 support is handled by the
        // engine pin in configureSpotBugs.
        if (languages.hasJava || languages.hasKotlin || languages.hasGroovy) {
            configureCheckstyle(project, configDir, extension)
            configurePmd(project, configDir, extension)
        }
        if (languages.hasJava && !languages.hasKotlin) {
            configureSpotBugs(project, extension)
        }

        if (languages.hasGroovy) {
            configureCodeNarc(project, configDir, extension)
        }

        // Detekt's `ignoreFailures` is a plain `var Boolean` (no lazy Provider hook in
        // 1.23.x), so the failure flag must be applied AFTER the consumer's
        // `octopusQuality { ... }` block — i.e. from this afterEvaluate path. Everything
        // else for detekt (config, baseline, reports) is set early via `registerEarly`.
        if (languages.hasKotlin) {
            project.plugins.withId("io.gitlab.arturbosch.detekt") {
                configureDetektFailureFlag(project, extension)
            }
        }

        // Coverage: skip for excluded projects
        val excludedFromCoverage = extension.coverageExcludedProjects.get()
        if (project.name !in excludedFromCoverage) {
            val overallLanguages = LanguageDetector.detectAll(rootProject, excludedFromCoverage)
            val coverageTool = resolveCoverageTool(extension.coverage.tool.get(), overallLanguages)
            when (coverageTool) {
                CoverageExtension.Tool.JACOCO -> configureJaCoCo(project, extension)
                CoverageExtension.Tool.KOVER -> configureKover(project, rootProject, extension)
                else -> {}
            }
        }
    }

    private fun resolveConfigDir(rootProject: Project): File =
        rootProject.extensions.extraProperties.let { extra ->
            val key = "octopusQuality.configDir"
            if (extra.has(key)) {
                extra.get(key) as File
            } else {
                ConfigExtractor.extractTo(rootProject).also { extra.set(key, it) }
            }
        }

    private fun configureCheckstyle(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("checkstyle")
        project.extensions.configure(org.gradle.api.plugins.quality.CheckstyleExtension::class.java) { ext ->
            ext.toolVersion = BuildConstants.CHECKSTYLE_VERSION
            ext.configFile = File(configDir, "checkstyle.xml")
            ext.isShowViolations = true
            ext.isIgnoreFailures = !extension.java.failOnViolation.get()
        }
        project.tasks.withType(org.gradle.api.plugins.quality.Checkstyle::class.java).configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
    }

    private fun configurePmd(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("pmd")
        project.extensions.configure(org.gradle.api.plugins.quality.PmdExtension::class.java) { ext ->
            ext.toolVersion = BuildConstants.PMD_VERSION
            ext.isConsoleOutput = true
            ext.incrementalAnalysis.set(true)
            ext.isIgnoreFailures = !extension.java.failOnViolation.get()
            ext.ruleSets = emptyList()
            ext.ruleSetFiles = project.files(File(configDir, "pmd-ruleset.xml"))
        }
        project.tasks.withType(org.gradle.api.plugins.quality.Pmd::class.java).configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
    }

    private fun configureSpotBugs(
        project: Project,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("com.github.spotbugs")
        project.extensions.configure(com.github.spotbugs.snom.SpotBugsExtension::class.java) { ext ->
            // Pin the analysis engine: the spotbugs-gradle-plugin default (4.8.x) ships ASM 9.7
            // and aborts on Java 25 bytecode (class file v69). 4.9.x brings ASM 9.9 / BCEL 6.11.
            ext.toolVersion.set(BuildConstants.SPOTBUGS_VERSION)
            ext.ignoreFailures.set(!extension.java.failOnViolation.get())
            ext.showProgress.set(false)
        }
        project.tasks.withType(com.github.spotbugs.snom.SpotBugsTask::class.java).configureEach { task ->
            // maybeCreate: safe whether or not reports are pre-registered
            task.reports
                .maybeCreate("xml")
                .required
                .set(true)
            task.reports
                .maybeCreate("html")
                .required
                .set(true)
        }
    }

    /**
     * Detekt's settings that must be in place before its tasks are wired (config,
     * baseline, reports). Runs from a `plugins.withId` callback during root script
     * evaluation — never call `.get()` on consumer extension properties here.
     * `ignoreFailures` is intentionally NOT set here (no lazy Provider hook exists in
     * detekt-gradle-plugin 1.23.x); see `configureDetektFailureFlag`.
     */
    private fun configureDetektEarly(
        project: Project,
        configDir: File,
    ) {
        project.extensions.configure(io.gitlab.arturbosch.detekt.extensions.DetektExtension::class.java) { ext ->
            ext.buildUponDefaultConfig = true
            ext.allRules = false
            ext.config.setFrom(File(configDir, "detekt.yml"))
            val baselineFile = File(project.projectDir, "detekt-baseline.xml")
            if (baselineFile.exists()) {
                ext.baseline = baselineFile
            }
        }
        project.tasks.withType(io.gitlab.arturbosch.detekt.Detekt::class.java).configureEach { task ->
            task.reports {
                it.xml.required.set(true)
                it.html.required.set(true)
                it.sarif.required.set(true)
                it.txt.required.set(false)
            }
        }
    }

    /**
     * Detekt's `DetektExtension.ignoreFailures` is a plain `var Boolean` with no lazy
     * Provider hook, so it must be set after the consumer's `octopusQuality { ... }`
     * block has been processed — i.e. from the afterEvaluate path.
     */
    private fun configureDetektFailureFlag(
        project: Project,
        extension: OctopusQualityExtension,
    ) {
        project.extensions.configure(io.gitlab.arturbosch.detekt.extensions.DetektExtension::class.java) { ext ->
            ext.ignoreFailures = !extension.kotlin.failOnViolation.get()
        }
    }

    /**
     * Runs from a `plugins.withId` callback during root script evaluation — never call
     * `.get()` on consumer extension properties here; use `.map { }` so the consumer's
     * `octopusQuality { ... }` override is observed when the property is finally read.
     */
    private fun configureKtlint(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        // Bundled .editorconfig is the authoritative source for ktlint editorconfig
        // values across the org. Parse it once at configuration time and feed the
        // ktlint-recognized keys into ktlint-gradle's additionalEditorconfig
        // MapProperty (14.x has no path-based editorconfig API). Fail-fast if the
        // resource is missing — that means jar packaging dropped the dotfile.
        val editorConfig = File(configDir, ".editorconfig")
        require(editorConfig.isFile) {
            "Bundled .editorconfig missing at ${editorConfig.absolutePath}. " +
                "Check gradle-quality-plugin resource packaging."
        }
        val editorConfigEntries = EditorConfigParser.parseKotlinSection(editorConfig)
        project.extensions.configure(org.jlleitschuh.gradle.ktlint.KtlintExtension::class.java) { ext ->
            ext.ignoreFailures.set(extension.kotlin.failOnViolation.map { !it })
            ext.outputToConsole.set(true)
            ext.reporters {
                it.reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.PLAIN)
                it.reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.CHECKSTYLE)
            }
            // Set the baseline path unconditionally — ktlint-gradle 14.0.1 treats a
            // missing baseline file as empty at task-execution time, so this is safe on
            // a fresh checkout. Side effect: `ktlintGenerateBaseline` writes to this
            // convention path directly, so consumers don't need to relocate the file
            // from ktlint-gradle's own default (`config/ktlint/baseline.xml`).
            ext.baseline.set(File(project.projectDir, "ktlint-baseline.xml"))
            ext.filter {
                it.exclude("**/generated/**")
                it.exclude("**/build/**")
                it.include("**/*.kt", "**/*.kts")
            }
            ext.additionalEditorconfig.putAll(editorConfigEntries)
        }
    }

    private fun configureCodeNarc(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("codenarc")
        project.extensions.configure(org.gradle.api.plugins.quality.CodeNarcExtension::class.java) { ext ->
            ext.configFile = File(configDir, "codenarc.groovy")
            ext.isIgnoreFailures = !extension.groovy.failOnViolation.get()
        }
        project.tasks.withType(org.gradle.api.plugins.quality.CodeNarc::class.java).configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
    }

    private fun configureJaCoCo(
        project: Project,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("jacoco")
        // Type-based filtering applies report config (XML+HTML, violation rules) to ANY
        // JacocoReport / JacocoCoverageVerification instance the consumer registers.
        val reportTasks = project.tasks.withType(org.gradle.testing.jacoco.tasks.JacocoReport::class.java)
        val verifyTasks = project.tasks.withType(org.gradle.testing.jacoco.tasks.JacocoCoverageVerification::class.java)

        // Dependency wiring is scoped to the standard `test` ↔ `jacocoTestReport` /
        // `jacocoTestCoverageVerification` triplet. Coupling every Test task to every
        // JacocoReport (and vice versa) over-couples projects with extra source sets
        // (e.g. `integrationTest` + `jacocoIntegrationTestReport`).
        val testTasks = project.tasks.withType(org.gradle.api.tasks.testing.Test::class.java)
        val defaultTestTask = testTasks.matching { it.name == "test" }
        val defaultReportTask = reportTasks.matching { it.name == "jacocoTestReport" }
        val defaultVerifyTask = verifyTasks.matching { it.name == "jacocoTestCoverageVerification" }

        defaultTestTask.configureEach { task -> task.finalizedBy(defaultReportTask) }
        defaultReportTask.configureEach { task -> task.dependsOn(defaultTestTask) }
        defaultVerifyTask.configureEach { task -> task.dependsOn(defaultTestTask) }

        reportTasks.configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
        verifyTasks.configureEach { task ->
            task.violationRules.rule { rule ->
                rule.element = "BUNDLE"
                rule.limit { limit ->
                    limit.counter = "LINE"
                    limit.value = "COVEREDRATIO"
                    limit.minimum = extension.coverage.minimumLineCoverage.get()
                }
            }
        }
    }

    @Suppress("UnusedParameter")
    private fun configureKover(
        project: Project,
        rootProject: Project,
        extension: OctopusQualityExtension,
    ) {
        // Kover is applied by consumer (with their version via pluginManagement).
        // Convention plugin only wires qualityCoverage tasks to kover tasks if they exist.
    }
}
