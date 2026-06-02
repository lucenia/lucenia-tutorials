plugins {
    java
    application
}

group = "io.lucenia.tutorials"
version = "1.0-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

repositories {
    mavenCentral()
}

val luceniaJavaVersion = "v0.11.0"

dependencies {
    implementation("io.lucenia.client:lucenia-java:$luceniaJavaVersion")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.0")
    implementation("org.apache.logging.log4j:log4j-api:[2.17.1,3.0)")
    implementation("org.apache.logging.log4j:log4j-core:[2.17.1,3.0)")
    implementation("org.apache.logging.log4j:log4j-slf4j2-impl:[2.17.1,3.0)")
    implementation("commons-logging:commons-logging:1.2")
}

application {
    mainClass.set("io.lucenia.tutorials.LuceniaJavaExample")
}
