package org.aibles.ecommerce.devbox_portal.service.impl;

import io.fabric8.kubernetes.api.model.batch.v1.Job;
import io.fabric8.kubernetes.api.model.batch.v1.JobStatusBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.JobView;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Against fabric8's in-memory API server: what Job the portal creates, and how it reads one back. */
@EnableKubernetesMockClient(crud = true)
class JobServiceImplTest {

    KubernetesClient client;

    private JobServiceImpl jobs;

    @BeforeEach
    void setUp() {
        jobs = new JobServiceImpl(client,
                new PortalProperties.Runner("localhost:5000/devbox-runner:abc1234", "devbox", "devbox-runner", 1),
                Clock.fixed(Instant.parse("2026-10-11T09:30:15Z"), ZoneOffset.UTC));
    }

    @Test
    void createsARunnerJobWithFixedArgumentsNotACommandLine() {
        JobView view = jobs.start("env-create", "cart");

        assertThat(view.name()).isEqualTo("devbox-env-create-cart-1011093015");
        assertThat(view.target()).isEqualTo("preview-cart");
        assertThat(view.status()).isEqualTo("PENDING");

        Job job = client.batch().v1().jobs().inNamespace("devbox").withName(view.name()).get();
        var container = job.getSpec().getTemplate().getSpec().getContainers().get(0);
        assertThat(container.getImage()).isEqualTo("localhost:5000/devbox-runner:abc1234");
        assertThat(container.getArgs()).containsExactly("env-create", "preview-cart");
        assertThat(job.getSpec().getTemplate().getSpec().getServiceAccountName()).isEqualTo("devbox-runner");
        assertThat(job.getSpec().getBackoffLimit()).isZero();
    }

    @Test
    void deleteIsAppliedNotADryRun() {
        JobView view = jobs.start("env-delete", "preview-cart");

        var args = client.batch().v1().jobs().inNamespace("devbox").withName(view.name()).get()
                .getSpec().getTemplate().getSpec().getContainers().get(0).getArgs();
        assertThat(args).containsExactly("env-delete", "preview-cart", "1");
    }

    @Test
    void rejectsNamesOutsideThePreviewGrammar() {
        assertThatThrownBy(() -> jobs.start("env-create", "Cart; rm -rf /"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> jobs.start("env-create", "prod-like-copy-but-way-too-long"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> jobs.start("shell", "cart"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void oneEnvJobAtATime() {
        jobs.start("env-create", "cart");

        assertThatThrownBy(() -> jobs.start("env-create", "other"))
                .isInstanceOf(PortalException.class)
                .satisfies(e -> assertThat(((PortalException) e).status()).isEqualTo(HttpStatus.CONFLICT));
    }

    @Test
    void aFinishedJobNoLongerBlocksTheNext() {
        JobView first = jobs.start("env-create", "cart");
        setStatus(first.name(), new JobStatusBuilder().withSucceeded(1)
                .withStartTime("2026-10-11T09:30:16Z").withCompletionTime("2026-10-11T09:36:00Z").build());

        JobView done = jobs.job(first.name());
        assertThat(done.status()).isEqualTo("SUCCEEDED");
        assertThat(done.finishedAt()).isEqualTo("2026-10-11T09:36:00Z");

        jobs.start("env-delete", "cart");   // no conflict
        assertThat(jobs.jobs()).hasSize(2);
    }

    @Test
    void failedAndRunningAreReadFromTheJobStatus() {
        JobView a = jobs.start("env-create", "cart");
        setStatus(a.name(), new JobStatusBuilder().withActive(1).withStartTime("2026-10-11T09:30:16Z").build());
        assertThat(jobs.job(a.name()).status()).isEqualTo("RUNNING");

        setStatus(a.name(), new JobStatusBuilder().withFailed(1)
                .addNewCondition().withType("Failed").withStatus("True").withLastTransitionTime("2026-10-11T09:31:00Z").endCondition()
                .build());
        JobView failed = jobs.job(a.name());
        assertThat(failed.status()).isEqualTo("FAILED");
        assertThat(failed.finishedAt()).isEqualTo("2026-10-11T09:31:00Z");
    }

    @Test
    void anUnknownOrForeignJobIsNotFound() {
        assertThatThrownBy(() -> jobs.job("devbox-nope"))
                .isInstanceOf(PortalException.class)
                .satisfies(e -> assertThat(((PortalException) e).status()).isEqualTo(HttpStatus.NOT_FOUND));
    }

    @Test
    void logIsEmptyWhileThePodDoesNotExistYet() {
        JobView view = jobs.start("env-create", "cart");

        assertThat(jobs.log(view.name())).isEmpty();
    }

    @Test
    void jobsAreDisabledWithoutARunnerImage() {
        JobServiceImpl off = new JobServiceImpl(client,
                new PortalProperties.Runner("", "devbox", "devbox-runner", 1), Clock.systemUTC());

        assertThatThrownBy(() -> off.start("env-create", "cart"))
                .isInstanceOf(PortalException.class)
                .hasMessageContaining("disabled");
    }

    private void setStatus(String name, io.fabric8.kubernetes.api.model.batch.v1.JobStatus status) {
        Job job = client.batch().v1().jobs().inNamespace("devbox").withName(name).get();
        job.setStatus(status);
        client.batch().v1().jobs().inNamespace("devbox").resource(job).updateStatus();
    }
}
