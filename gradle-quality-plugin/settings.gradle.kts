pluginManagement {
    val detektVersion: String by settings
    val ktlintGradleVersion: String by settings

    plugins {
        id("io.gitlab.arturbosch.detekt") version detektVersion
        id("org.jlleitschuh.gradle.ktlint") version ktlintGradleVersion
    }

    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

rootProject.name = "octopus-quality-plugin"
