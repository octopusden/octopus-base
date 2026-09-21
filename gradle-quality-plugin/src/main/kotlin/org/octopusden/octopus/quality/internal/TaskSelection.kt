package org.octopusden.octopus.quality.internal

/**
 * Fully qualified path of [taskName] in the project at [projectPath].
 *
 * The root project's path is already `":"`, so naive interpolation would yield `"::test"` and
 * never match an exclusion a consumer wrote as `":test"`.
 */
internal fun qualifiedTaskPath(
    projectPath: String,
    taskName: String,
): String = if (projectPath == ":") ":$taskName" else "$projectPath:$taskName"

/**
 * True when [taskName] in the project at [projectPath] is excluded, by bare name or by fully
 * qualified path.
 *
 * A bare name excludes that task in every module; the qualified form excludes it in one.
 */
internal fun isTaskExcluded(
    projectPath: String,
    taskName: String,
    excludedTasks: Set<String>,
): Boolean = taskName in excludedTasks || qualifiedTaskPath(projectPath, taskName) in excludedTasks

/**
 * True when [taskName] in the project at [projectPath] is a suite whose coverage the aggregated
 * JaCoCo report counts: the standard `test`, plus anything declared in [additionalTestTasks],
 * minus anything in [excludedTasks]. Exclusion wins over declaration.
 *
 * Extra suites are opt-in rather than automatic, following `SubprojectConfigurer.configureJaCoCo`,
 * which scopes its wiring to the standard `test` / `jacocoTestReport` /
 * `jacocoTestCoverageVerification` triplet instead of coupling every `Test` task to every report
 * task. With nothing declared this selects exactly what the aggregate selected before the property
 * existed, so adding it moves no existing consumer.
 */
internal fun isCoverageSuite(
    projectPath: String,
    taskName: String,
    excludedTasks: Set<String>,
    additionalTestTasks: Set<String>,
): Boolean =
    (taskName == "test" || taskName in additionalTestTasks) &&
        !isTaskExcluded(projectPath, taskName, excludedTasks)
