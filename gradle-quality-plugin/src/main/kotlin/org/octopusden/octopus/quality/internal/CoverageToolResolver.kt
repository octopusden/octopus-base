package org.octopusden.octopus.quality.internal

import org.octopusden.octopus.quality.CoverageExtension

internal fun resolveCoverageTool(
    requested: CoverageExtension.Tool,
    languages: DetectedLanguages,
): CoverageExtension.Tool {
    if (requested != CoverageExtension.Tool.AUTO) return requested
    return if (languages.isKotlinOnly) CoverageExtension.Tool.KOVER else CoverageExtension.Tool.JACOCO
}
