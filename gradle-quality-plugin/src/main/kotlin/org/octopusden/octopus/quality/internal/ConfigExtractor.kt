package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import java.io.File

/**
 * Extracts bundled config files from plugin resources into Gradle's project cache
 * directory (`.gradle/` by default, overridable via `--project-cache-dir`) so that
 * Gradle quality tools can reference them by file path and the files survive
 * `./gradlew clean`.
 */
internal object ConfigExtractor {
    private const val RESOURCE_PREFIX = "org/octopusden/octopus/quality/config"

    private val CONFIG_FILES =
        listOf(
            "detekt.yml",
            "checkstyle.xml",
            "pmd-ruleset.xml",
            "codenarc.groovy",
            ".editorconfig",
        )

    /**
     * Extract all config files to `<projectCacheDir>/octopus-quality/config/`.
     *
     * Uses Gradle's project cache directory (not `build/`) so the extracted config
     * survives `./gradlew clean` — otherwise a `clean build` run deletes configs
     * between configuration phase (when extraction happens) and execution phase
     * (when detekt etc. read them).
     *
     * Respects `--project-cache-dir` / `projectCacheDir` settings overrides and
     * falls back to the Gradle default (`<rootDir>/.gradle`) when unset.
     *
     * Returns the config directory.
     */
    fun extractTo(project: Project): File {
        val projectCacheDir =
            project.gradle.startParameter.projectCacheDir
                ?: File(project.rootDir, ".gradle")
        val configDir = File(projectCacheDir, "octopus-quality/config")
        if (!configDir.isDirectory && !configDir.mkdirs()) {
            error("Failed to create config directory: ${configDir.absolutePath}")
        }

        for (fileName in CONFIG_FILES) {
            val target = File(configDir, fileName)
            val resource =
                javaClass.classLoader.getResourceAsStream("$RESOURCE_PREFIX/$fileName")
                    ?: error("Missing bundled config: $RESOURCE_PREFIX/$fileName")
            resource.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
        }

        return configDir
    }
}
