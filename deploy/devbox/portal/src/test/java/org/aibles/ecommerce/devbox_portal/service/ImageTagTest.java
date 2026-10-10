package org.aibles.ecommerce.devbox_portal.service;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ImageTagTest {

    private static final String FILE = """
            # order-service in prod-like. One file = one Argo CD Application.
            # Deploy another version: change image.tag and commit.
            apps:
              order-service:
                image:
                  tag: ac48ad8   # pinned for the perf baseline
                springConfig:
                  application:
                    kafka:
                      group-id:
                        tag: not-this-one
            """;

    @Test
    void readsTheImageTagNotAnyOtherTagKey() {
        assertThat(ImageTag.current(FILE)).contains("ac48ad8");
    }

    @Test
    void rewritesOnlyTheTagAndKeepsEveryComment() {
        String out = ImageTag.withTag(FILE, "9f8e7d6-dirty-1010-0932");

        assertThat(ImageTag.current(out)).contains("9f8e7d6-dirty-1010-0932");
        assertThat(out)
                .contains("# order-service in prod-like.")
                .contains("# pinned for the perf baseline")
                .contains("tag: not-this-one");
        // One line changed, nothing else: same length minus old tag plus new one.
        assertThat(out.length()).isEqualTo(FILE.length() - "ac48ad8".length() + "9f8e7d6-dirty-1010-0932".length());
    }

    @Test
    void worksWhenTheTagIsTheLastLine() {
        String file = "apps:\n  frontend:\n    image:\n      tag: dev";
        assertThat(ImageTag.withTag(file, "b49a101")).endsWith("tag: b49a101");
    }

    @Test
    void refusesAnythingThatIsNotATag() {
        assertThatThrownBy(() -> ImageTag.withTag(FILE, "x\n    hpa: null"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> ImageTag.withTag(FILE, "../../etc"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void refusesAFileWithoutAnImageTag() {
        assertThat(ImageTag.current("envRedis:\n  enabled: true\n")).isEmpty();
        assertThatThrownBy(() -> ImageTag.withTag("envRedis:\n  enabled: true\n", "dev"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
