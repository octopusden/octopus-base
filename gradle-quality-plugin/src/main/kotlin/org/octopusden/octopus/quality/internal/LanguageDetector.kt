package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import java.io.File

internal data class DetectedLanguages(
    val hasKotlin: Boolean,
    val hasJava: Boolean,
    val hasGroovy: Boolean,
) {
    val isKotlinOnly get() = hasKotlin && !hasJava && !hasGroovy
}

internal object LanguageDetector {

    private val SOURCE_DIRS = listOf("src/main", "src/test", "src/integrationTest", "src/testFixtures")

    fun detect(project: Project): DetectedLanguages {
        var hasKotlin = false
        var hasJava = false
        var hasGroovy = false

        for (base in SOURCE_DIRS) {
            if (File(project.projectDir, "$base/kotlin").exists()) hasKotlin = true
            if (File(project.projectDir, "$base/java").exists()) hasJava = true
            if (File(project.projectDir, "$base/groovy").exists()) hasGroovy = true
        }

        return DetectedLanguages(hasKotlin, hasJava, hasGroovy)
    }

    /**
     * Detect languages across all subprojects (or the root project if single-module).
     */
    fun detectAll(rootProject: Project, excludedProjects: Set<String>): DetectedLanguages {
        val projects = if (rootProject.subprojects.isEmpty()) {
            listOf(rootProject)
        } else {
            rootProject.subprojects.filter { it.name !in excludedProjects }
        }

        var hasKotlin = false
        var hasJava = false
        var hasGroovy = false

        for (project in projects) {
            val lang = detect(project)
            if (lang.hasKotlin) hasKotlin = true
            if (lang.hasJava) hasJava = true
            if (lang.hasGroovy) hasGroovy = true
        }

        return DetectedLanguages(hasKotlin, hasJava, hasGroovy)
    }
}
