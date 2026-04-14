package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import java.io.File

/**
 * Extracts bundled config files from plugin resources into the build directory
 * so that Gradle quality tools can reference them by file path.
 */
internal object ConfigExtractor {
    private const val RESOURCE_PREFIX = "org/octopusden/octopus/quality/config"

    private val CONFIG_FILES =
        listOf(
            "detekt.yml",
            "checkstyle.xml",
            "pmd-ruleset.xml",
            "codenarc.groovy",
        )

    /**
     * Extract all config files to `<rootBuildDir>/octopus-quality/config/`.
     * Returns the config directory.
     */
    fun extractTo(project: Project): File {
        val configDir =
            File(
                project.layout.buildDirectory.asFile
                    .get(),
                "octopus-quality/config",
            )
        configDir.mkdirs()

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
