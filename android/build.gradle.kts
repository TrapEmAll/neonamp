allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// dart_smb2 ships an emulator-only x86_64 binary by default. NeonAmp's
// Android distribution is ARM-only, so remove that ABI after the plugin's
// Android library project has been evaluated. This also prevents the plugin's
// download task from fetching the unused binary in the first place.
subprojects {
    afterEvaluate {
        if (name == "dart_smb2") {
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                defaultConfig {
                    ndk {
                        abiFilters.remove("x86_64")
                    }
                }
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

