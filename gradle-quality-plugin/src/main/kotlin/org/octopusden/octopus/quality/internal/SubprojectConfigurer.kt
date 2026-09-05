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
     * Minimum JDK an ErrorProne engine release can RUN on, derived from its bytecode target — an
     * objective property of the jar, unlike the upper bound, which is a per-JDK empirical result and
     * is therefore documented rather than enforced.
     *
     * Entries descend, and the floor only ever rises across releases, so the first entry at or below
     * the requested version gives the answer — including for a future release newer than anything
     * listed here.
     */
    private val ERRORPRONE_JDK_FLOORS =
        listOf(
            listOf(2, 50, 0) to 21,
            listOf(2, 32, 0) to 17,
            listOf(0, 0, 0) to 11,
        )

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

        // Checkstyle/PMD are Java-only tools (they analyse `.java` *source*), so apply them only
        // to modules that actually have Java source — applying them to Kotlin-only / Groovy-only
        // modules just adds no-op tasks (and misleadingly-named ones) to the graph. SpotBugs
        // analyses *bytecode* and scans the module's whole compiled output: when Kotlin is present
        // it reads the Kotlin classes too and produces ~95% false positives (lateinit / DSL getters
        // / synthetic accessors). Gate it to modules that have Java and NO Kotlin (Java-only or
        // Java+Groovy qualify — only Kotlin triggers the false-positive flood). Java 25 / class file
        // v69 support is handled by the engine pin in configureSpotBugs.
        if (languages.hasJava) {
            configureCheckstyle(project, configDir, extension)
            configurePmd(project, configDir, extension)
            // Opt-in (octopusQuality { java { errorProne.set(true) } }): applied ONLY when asked
            // for. Applying it "disabled" is not free — it still registers the javac plugin and
            // forks the compiler — so an opted-out repo neither pays for it nor risks a compile
            // that behaves differently from a plain javac one.
            if (extension.java.errorProne.get()) {
                configureErrorProne(project, extension)
            }
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

    /**
     * ErrorProne runs inside javac, so unlike SpotBugs it sees only `.java` SOURCE — a Kotlin
     * module is invisible to it and needs no exclusion, which is why this sits under `hasJava`
     * alone rather than SpotBugs' `hasJava && !hasKotlin`.
     *
     * `disableAllWarnings` narrows the run to the on-by-default ERROR checks. That is the whole
     * point of the default configuration: those checks are the ones ErrorProne considers always
     * a bug, so they need no baseline and no tuning, whereas its warning set on legacy code is a
     * wall of findings nobody triages. `allErrorsAsWarnings` then hands the pass/fail decision to
     * the same `java.failOnViolation` switch checkstyle/pmd/spotbugs already obey — for every
     * check that permits it. ErrorProne applies that demotion only to checks declaring
     * `disableable = true` (`ScannerSupplier.applyOverrides`), so a non-disableable ERROR such as
     * `UnicodeDirectionalityCharacters` fails the compile whatever this switch says. That is the
     * upstream contract, not something this configuration can override.
     *
     * `--add-exports`/`--add-opens` for JDK 16+ are added by the Gradle plugin itself
     * (`ErrorProneJvmArgumentProvider`); nothing here needs to configure forking.
     *
     * TD-003 records that the tests below JDK 16 never reach the forked-compiler path consumers
     * take (see docs/Octopus Tech Debt Register.md).
     *
     * KNOWN LIMITATION of applying from this (afterEvaluate) phase: `options.errorprone` does not
     * exist while the consumer's subproject script evaluates, so a repository cannot tune
     * individual checks there — see the documented `afterEvaluate` workaround in
     * `docs/Octopus JVM Style Guidelines.md`. Applying the plugin from `registerEarly` instead and
     * driving `options.errorprone.isEnabled` from a lazy Provider would restore that surface; it is
     * not done yet because it would apply the plugin to every module rather than only the opted-in
     * Java ones, and nothing has opted in. Revisit when the first consumer needs per-check tuning.
     */
    private fun configureErrorProne(
        project: Project,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("net.ltgt.errorprone")
        project.dependencies.add(
            "errorprone",
            "com.google.errorprone:error_prone_core:${extension.java.errorProneVersion.get()}",
        )
        // Read eagerly: this runs from the subproject afterEvaluate, so the consumer's
        // octopusQuality { } block has already been processed.
        val errorsAsWarnings = !extension.java.failOnViolation.get()
        val engineVersion = extension.java.errorProneVersion.get()
        project.tasks.withType(org.gradle.api.tasks.compile.JavaCompile::class.java).configureEach { task ->
            // Floor guard, at EXECUTION time so the toolchain is resolved (the Gradle JVM is not
            // necessarily the compile JVM) and so a task that never compiles is unaffected.
            // Without it, an engine newer than the compile JDK fails inside javac as a bare
            // UnsupportedClassVersionError naming neither ErrorProne nor `errorProneVersion`.
            task.doFirst {
                val compileJdk =
                    task.javaCompiler.orNull
                        ?.metadata
                        ?.languageVersion
                        ?.asInt()
                        ?: org.gradle.api.JavaVersion
                            .current()
                            .majorVersion
                            .toInt()
                val floor = errorProneJdkFloor(engineVersion)
                if (compileJdk < floor) {
                    throw org.gradle.api.GradleException(
                        "ErrorProne engine $engineVersion requires JDK $floor or newer, but " +
                            "${task.path} compiles on JDK $compileJdk. Either lower " +
                            "octopusQuality { java { errorProneVersion } } or raise this module's " +
                            "Java toolchain. Engine/JDK matrix: " +
                            "docs/Octopus Quality Plugin CI Reference.md",
                    )
                }
            }
            // `CompileOptions` is ExtensionAware only at runtime — the compile-time type does not
            // declare it — so the extension is fetched through an explicit cast.
            val options =
                (task.options as org.gradle.api.plugins.ExtensionAware)
                    .extensions
                    .getByType(net.ltgt.gradle.errorprone.ErrorProneOptions::class.java)
            options.disableAllWarnings.set(true)
            options.allErrorsAsWarnings.set(errorsAsWarnings)
        }
    }

    private fun errorProneJdkFloor(version: String): Int {
        val parsed =
            version
                .split('.', '-')
                .mapNotNull { it.toIntOrNull() }
        return ERRORPRONE_JDK_FLOORS
            .first { (from, _) -> compareVersions(parsed, from) >= 0 }
            .second
    }

    private fun compareVersions(
        left: List<Int>,
        right: List<Int>,
    ): Int {
        for (i in 0 until maxOf(left.size, right.size)) {
            val diff = (left.getOrElse(i) { 0 }) - (right.getOrElse(i) { 0 })
            if (diff != 0) return diff
        }
        return 0
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
            // Exclude the project's ACTUAL build output dir by absolute path — NOT a "**/build/**"
            // glob. That glob matches any path segment named "build", so a repo whose package path
            // contains `build` (e.g. org.octopusden.octopus.build.integration) would have EVERY source
            // file excluded and ktlint would run hollow (0 files) despite the task existing.
            // buildDirectory is resolved lazily INSIDE the exclude spec (evaluated at task time) so a
            // consumer's later buildDir customization is honored.
            val buildDirectory = project.layout.buildDirectory
            ext.filter {
                it.exclude { element ->
                    val buildPath =
                        buildDirectory
                            .get()
                            .asFile
                            .toPath()
                            .toAbsolutePath()
                            .normalize()
                    element.file
                        .toPath()
                        .toAbsolutePath()
                        .normalize()
                        .startsWith(buildPath)
                }
                it.exclude("**/generated/**")
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

        // Coverage semantics (read eagerly — this runs from the subproject afterEvaluate, so the
        // consumer's octopusQuality { } block has already been processed). These are structural
        // task-graph decisions, so they cannot be deferred to a lazy Provider.
        val coverageEnabled = extension.coverage.enabled.get()
        val verifyInCheck = extension.coverage.verifyInCheck.get()

        // Report-on-check follows `enabled`: the jacoco plugin ties the report to `check` only
        // through this `test.finalizedBy(jacocoTestReport)` edge, so gating it here removes the
        // report from `check` when coverage is disabled.
        if (coverageEnabled) {
            defaultTestTask.configureEach { task -> task.finalizedBy(defaultReportTask) }
        }
        defaultReportTask.configureEach { task -> task.dependsOn(defaultTestTask) }
        defaultVerifyTask.configureEach { task -> task.dependsOn(defaultTestTask) }

        // Unlike Kover, Gradle's jacoco plugin does NOT put verification on `check` by default, so
        // there is no pre-existing floor to remove. Add the opt-in edge only when the consumer asks
        // for it. Wired lazily via `matching` so it is safe regardless of plugin application order.
        if (coverageEnabled && verifyInCheck) {
            project.tasks.matching { it.name == "check" }.configureEach { task ->
                task.dependsOn(defaultVerifyTask)
            }
        }

        reportTasks.configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
        // Configure the violation rule only when coverage is enabled — an enabled=false project has
        // no floor at all, so a direct `jacocoTestCoverageVerification` invocation passes vacuously.
        if (coverageEnabled) {
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
    }

    @Suppress("UnusedParameter")
    private fun configureKover(
        project: Project,
        rootProject: Project,
        extension: OctopusQualityExtension,
    ) {
        // Kover is applied by the consumer (version via pluginManagement). When present, enforce the
        // same per-module line-coverage floor the JaCoCo path enforces. Previously this was a no-op,
        // so `koverVerify` passed with NO threshold — a coverage gate that measured nothing.
        project.plugins.withId("org.jetbrains.kotlinx.kover") {
            val coverage = extension.coverage
            val minPercent =
                coverage.minimumLineCoverage
                    .get()
                    .movePointRight(2)
                    .toInt()
                    .coerceIn(0, 100)
            // Structural gate for the rule (read eagerly — runs from the subproject afterEvaluate,
            // so the consumer's octopusQuality { } block is already processed). The onCheck flags
            // below are wired lazily as Providers.
            val coverageEnabled = coverage.enabled.get()
            project.extensions.configure(kotlinx.kover.gradle.plugin.dsl.KoverProjectExtension::class.java) { kover ->
                kover.reports { reports ->
                    // Report-on-check follows `enabled`. Verify-on-check is opt-in: Kover binds
                    // `koverVerify` into `check` by default via `total.verify.onCheck.convention(true)`,
                    // so we ACTIVELY set it to false unless the consumer asked for `verifyInCheck` —
                    // this is the loosening relative to #147, which always enforced the floor on check.
                    reports.total { total ->
                        total.xml.onCheck.set(coverage.enabled)
                        total.html.onCheck.set(coverage.enabled)
                        total.verify.onCheck.set(
                            coverage.enabled.zip(coverage.verifyInCheck) { enabled, verify -> enabled && verify },
                        )
                    }
                    // Configure the floor rule only when coverage is enabled — an enabled=false
                    // project has no rule at all, so a direct `koverVerify` invocation passes vacuously.
                    if (coverageEnabled) {
                        reports.verify { verify ->
                            verify.rule { rule ->
                                rule.minBound(
                                    minValue = minPercent,
                                    coverageUnits = kotlinx.kover.gradle.plugin.dsl.CoverageUnit.LINE,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
