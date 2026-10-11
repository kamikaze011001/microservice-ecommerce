package org.aibles.ecommerce.devbox_portal.service.impl;

import org.aibles.ecommerce.devbox_portal.service.TestAssets;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/** Against the repo's real api-tests/ and deploy/k6-stress/ (tests run from deploy/devbox/portal). */
class TestAssetsImplTest {

    private static final Path REPO = Path.of("../../..").toAbsolutePath().normalize();
    private final TestAssetsImpl assets = new TestAssetsImpl(
            REPO.resolve("api-tests"), REPO.resolve("deploy/k6-stress"), System.getProperty("k6", "k6"));

    @Test
    void readsTheWholeBrunoCollectionWithRelativePaths() {
        List<TestAssets.BrunoFile> files = assets.brunoFiles();

        assertThat(files).extracting(TestAssets.BrunoFile::path)
                .contains("collection.bru", "environments/devbox.bru", "02 Auth/login.bru");
        assertThat(files).filteredOn(f -> f.path().equals("02 Auth/login.bru")).singleElement()
                .satisfies(f -> assertThat(f.content()).contains("bru.setVar(\"accessToken\""));
    }

    @Test
    void theRequestNamesAreTheK6Tags() {
        String src = "http.post(u, b, { tags: { name: 'login' } });\nhttp.get(u, { tags: { name: \"browse\" } });";
        assertThat(TestAssetsImpl.requestNames(src)).containsExactly("login", "browse");
    }

    @Test
    void theDescriptionIsTheScriptsOpeningComment() {
        String src = "// Runs login -> order.\n// Second line.\n\nimport http from 'k6/http';\n// not this";
        assertThat(TestAssetsImpl.description(src)).isEqualTo("Runs login -> order.\nSecond line.");
    }

    @Test
    void unknownScenariosAndProfilesAreRefusedBeforeAnythingRuns() {
        assertThatThrownBy(() -> assets.perfSettings("payment", "soak")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> assets.perfSettings("../etc", "smoke")).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void k6ResolvesTheRealSettings() {
        assumeTrue(onPath("k6"), "k6 not installed here — covered live in the portal image");

        TestAssets.PerfSettings s = assets.perfSettings("payment", "smoke");
        assertThat(s.scenarios().path("default").path("vus").asInt()).isEqualTo(3);
        assertThat(s.thresholds().has("http_req_failed")).isTrue();
        assertThat(s.requests()).contains("login", "create_order");
    }

    private static boolean onPath(String bin) {
        for (String dir : System.getenv("PATH").split(":")) {
            if (Files.isExecutable(Path.of(dir, bin))) {
                return true;
            }
        }
        return false;
    }
}
