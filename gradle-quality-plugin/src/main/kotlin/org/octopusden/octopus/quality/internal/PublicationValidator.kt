package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import org.gradle.api.publish.PublishingExtension
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.publish.maven.tasks.GenerateMavenPom
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Registers a `validatePublications` task that checks Maven Central readiness
 * by parsing the generated POM XML files.
 *
 * For non-pom publications (jar, etc.):
 * - POM has required fields: name, description, url, licenses, scm, developers
 * - Publication includes sources and javadoc JARs
 *
 * For pom-only publications (java-platform, BOM, version-catalog):
 * - Only POM metadata is validated (no sources/javadoc required)
 *
 * Wired into `check` (when available) so issues are caught on PR, not at publish time.
 */
internal object PublicationValidator {
    fun register(project: Project) {
        project.plugins.withId("maven-publish") {
            val validateTask =
                project.tasks.register("validatePublications") { task ->
                    task.group = "verification"
                    task.description =
                        "Validates that Maven publications meet Central Portal requirements"

                    // Depend on POM generation so we can parse the XML
                    task.dependsOn(
                        project.tasks.withType(GenerateMavenPom::class.java),
                    )

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
                            val pomOnly = isPomOnly(pub)

                            validatePomFromXml(project, pub, prefix, errors)

                            if (!pomOnly) {
                                validateArtifacts(pub, prefix, errors)
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

            // Wire into check lazily — safe regardless of plugin application order
            project.tasks.matching { it.name == "check" }.configureEach {
                it.dependsOn(validateTask)
            }
        }
    }

    /**
     * Parse the generated POM XML and validate required Maven Central fields.
     */
    private fun validatePomFromXml(
        project: Project,
        pub: MavenPublication,
        prefix: String,
        errors: MutableList<String>,
    ) {
        // Resolve POM file from the actual GenerateMavenPom task output (not hardcoded path)
        val pubNameCap = pub.name.replaceFirstChar { it.uppercase() }
        val pomTaskName = "generatePomFileFor${pubNameCap}Publication"
        val pomTask = project.tasks.findByName(pomTaskName) as? GenerateMavenPom
        val pomFile =
            pomTask?.destination ?: run {
                errors.add("$prefix: GenerateMavenPom task '$pomTaskName' not found")
                return
            }

        if (!pomFile.exists()) {
            errors.add("$prefix: generated POM not found at ${pomFile.path}")
            return
        }

        val dbf = DocumentBuilderFactory.newInstance()
        // Harden against XXE / entity expansion
        dbf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        dbf.setFeature("http://xml.org/sax/features/external-general-entities", false)
        dbf.setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        val doc = dbf.newDocumentBuilder().parse(pomFile)
        val root = doc.documentElement

        // Only look at direct children of <project>, not nested descendants.
        // This prevents <license><name> from satisfying the top-level <name> check.
        val directChildren =
            (0 until root.childNodes.length)
                .map { root.childNodes.item(it) }
                .filter { it.nodeType == org.w3c.dom.Node.ELEMENT_NODE }

        fun directChild(tag: String): org.w3c.dom.Node? = directChildren.firstOrNull { it.nodeName == tag }

        fun textOf(tag: String): String? = directChild(tag)?.textContent?.trim()?.ifBlank { null }

        fun hasChildElements(tag: String): Boolean {
            val node = directChild(tag) ?: return false
            return (0 until node.childNodes.length).any {
                node.childNodes.item(it).nodeType == org.w3c.dom.Node.ELEMENT_NODE
            }
        }

        if (textOf("name").isNullOrBlank()) {
            errors.add("$prefix: POM <name> is missing or blank")
        }
        if (textOf("description").isNullOrBlank()) {
            errors.add("$prefix: POM <description> is missing or blank")
        }
        if (textOf("url").isNullOrBlank()) {
            errors.add("$prefix: POM <url> is missing or blank")
        }
        if (!hasChildElements("licenses")) {
            errors.add("$prefix: POM <licenses> section is missing or empty")
        }
        if (!hasChildElements("developers")) {
            errors.add("$prefix: POM <developers> section is missing or empty")
        }
        if (!hasChildElements("scm")) {
            errors.add("$prefix: POM <scm> section is missing or empty")
        }
    }

    private fun validateArtifacts(
        pub: MavenPublication,
        prefix: String,
        errors: MutableList<String>,
    ) {
        // Maven Central requires -sources.jar and -javadoc.jar specifically (not .zip etc.)
        val hasSourcesJar =
            pub.artifacts.any {
                it.classifier == "sources" && it.extension == "jar"
            }
        val hasJavadocJar =
            pub.artifacts.any {
                it.classifier == "javadoc" && it.extension == "jar"
            }
        if (!hasSourcesJar) {
            errors.add("$prefix: sources JAR missing (Maven Central requires -sources.jar)")
        }
        if (!hasJavadocJar) {
            errors.add("$prefix: javadoc JAR missing (Maven Central requires -javadoc.jar)")
        }
    }

    /**
     * Detect pom-only publications: java-platform, BOM, version-catalog.
     * A publication is pom-only if:
     * - packaging is explicitly "pom", OR
     * - it has no non-metadata artifacts (no jar, war, ear, etc.)
     *
     * Metadata-only classifiers (sources, javadoc) don't count as "real" artifacts.
     */
    private fun isPomOnly(pub: MavenPublication): Boolean {
        if (pub.pom.packaging == "pom") return true
        val metadataClassifiers = setOf("sources", "javadoc")
        val hasRealArtifact =
            pub.artifacts.any { artifact ->
                artifact.classifier !in metadataClassifiers
            }
        return !hasRealArtifact
    }
}
