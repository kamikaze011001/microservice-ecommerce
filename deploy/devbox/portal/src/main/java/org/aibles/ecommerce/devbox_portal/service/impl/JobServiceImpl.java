package org.aibles.ecommerce.devbox_portal.service.impl;

import io.fabric8.kubernetes.api.model.Pod;
import io.fabric8.kubernetes.api.model.Quantity;
import io.fabric8.kubernetes.api.model.VolumeBuilder;
import io.fabric8.kubernetes.api.model.VolumeMountBuilder;
import io.fabric8.kubernetes.api.model.batch.v1.Job;
import io.fabric8.kubernetes.api.model.batch.v1.JobBuilder;
import io.fabric8.kubernetes.api.model.batch.v1.JobCondition;
import io.fabric8.kubernetes.api.model.batch.v1.JobStatus;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.KubernetesClientException;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.JobView;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.aibles.ecommerce.devbox_portal.service.JobKind;
import org.aibles.ecommerce.devbox_portal.service.JobService;

import java.time.Clock;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Runs devbox.sh in a Job (image devbox-runner, ServiceAccount devbox-runner)
 * instead of on a laptop. The Job IS the record: its labels say what ran
 * against which env, its status says how it went, its pod keeps the log —
 * no portal database. Finished Jobs are kept a week (ttlSecondsAfterFinished).
 */
@Slf4j
public class JobServiceImpl implements JobService {

    static final String PART_OF = "devbox-job";
    static final String KIND_LABEL = "devbox.job/kind";
    static final String TARGET_LABEL = "devbox.job/target";
    static final String TITLE_ANNOTATION = "devbox.job/title";
    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("MMddHHmmss").withZone(ZoneOffset.UTC);

    private final KubernetesClient kubernetes;
    private final PortalProperties.Runner runner;
    private final Clock clock;

    public JobServiceImpl(KubernetesClient kubernetes, PortalProperties.Runner runner, Clock clock) {
        this.kubernetes = kubernetes;
        this.runner = runner;
        this.clock = clock;
    }

    @Override
    public JobView start(String kindId, String target, Map<String, String> params) {
        if (runner.image() == null || runner.image().isBlank()) {
            throw PortalException.unprocessable("jobs are disabled: no runner image configured (devbox.runner.image)");
        }
        JobKind kind = JobKind.of(kindId);
        String env = kind.normalizeTarget(target);

        // Env jobs share the env repo and the cluster-wide cap — one at a time.
        jobs().stream().filter(j -> isActive(j.status())).findFirst().ifPresent(j -> {
            throw PortalException.conflict("'" + j.title() + " " + j.target() + "' is still running — wait for it to finish");
        });

        // A Job name is a DNS label (≤63): devbox-<kind>-<env> cut to 52, + "-MMddHHmmss".
        List<String> args = kind.args(env, params);   // validates params before anything is created
        String base = "devbox-" + kind.id() + "-" + env.replaceFirst("^preview-", "");
        String name = base.substring(0, Math.min(base.length(), 52)).replaceAll("-+$", "")
                + "-" + STAMP.format(clock.instant());
        Map<String, String> labels = Map.of(
                "app.kubernetes.io/part-of", PART_OF, KIND_LABEL, kind.id(), TARGET_LABEL, env);

        Job job = new JobBuilder()
                .withNewMetadata().withName(name).withNamespace(runner.namespace()).withLabels(labels)
                    .addToAnnotations(TITLE_ANNOTATION, kind.describe(params)).endMetadata()
                .withNewSpec()
                    .withBackoffLimit(0)                       // a half-done env step must not silently re-run
                    .withActiveDeadlineSeconds(1800L)
                    .withTtlSecondsAfterFinished(7 * 24 * 3600)
                    .withNewTemplate()
                        .withNewMetadata().withLabels(labels).endMetadata()
                        .withNewSpec()
                            .withServiceAccountName(runner.serviceAccount())
                            .withRestartPolicy("Never")
                            .addNewContainer()
                                .withName("runner")
                                .withImage(runner.image())
                                .withImagePullPolicy("IfNotPresent")
                                .withArgs(args)
                                .addNewEnv().withName("MAX_PREVIEWS").withValue(String.valueOf(runner.maxPreviews())).endEnv()
                                .withNewResources()
                                    .addToRequests("cpu", new Quantity("100m"))
                                    .addToRequests("memory", new Quantity("128Mi"))
                                    .addToLimits("memory", new Quantity("512Mi"))
                                .endResources()
                            .endContainer()
                        .endSpec()
                    .endTemplate()
                .endSpec()
                .build();
        if (kind.needsDocker()) {
            useNodeDocker(job);
        }
        try {
            Job created = kubernetes.batch().v1().jobs().inNamespace(runner.namespace()).resource(job).create();
            log.info("portal job started. job={} kind={} env={}", name, kind.id(), env);
            return view(created);
        } catch (KubernetesClientException e) {
            throw PortalException.upstream("the Kubernetes API (create Job)", e);
        }
    }

    /**
     * A build runs `docker build` on the node it lands on (the cluster's runtime
     * is Docker) and pushes to localhost:5000 — the node's own path to the
     * registry, the one pods pull through. Host network makes that localhost
     * the node's; ClusterFirstWithHostNet keeps Service DNS (Gitea) working.
     * Only build Jobs get this — it is root on the node.
     */
    private static void useNodeDocker(Job job) {
        var pod = job.getSpec().getTemplate().getSpec();
        pod.setHostNetwork(true);
        pod.setDnsPolicy("ClusterFirstWithHostNet");
        pod.getVolumes().add(new VolumeBuilder().withName("docker")
                .withNewHostPath().withPath("/var/run/docker.sock").withType("Socket").endHostPath().build());
        pod.getContainers().get(0).getVolumeMounts().add(new VolumeMountBuilder()
                .withName("docker").withMountPath("/var/run/docker.sock").build());
        job.getSpec().setActiveDeadlineSeconds(3600L);   // a cold build compiles cores + the service
    }

    @Override
    public List<JobView> jobs() {
        try {
            return kubernetes.batch().v1().jobs().inNamespace(runner.namespace())
                    .withLabel("app.kubernetes.io/part-of", PART_OF).list().getItems().stream()
                    .sorted(Comparator.comparing((Job j) -> Objects.toString(j.getMetadata().getCreationTimestamp(), "")).reversed())
                    .map(this::view)
                    .toList();
        } catch (KubernetesClientException e) {
            throw PortalException.upstream("the Kubernetes API (list Jobs)", e);
        }
    }

    @Override
    public JobView job(String name) {
        return view(find(name));
    }

    @Override
    public String log(String name) {
        find(name);
        try {
            List<Pod> pods = kubernetes.pods().inNamespace(runner.namespace()).withLabel("job-name", name).list().getItems();
            if (pods.isEmpty()) {
                return "";
            }
            return Objects.toString(kubernetes.pods().inNamespace(runner.namespace())
                    .withName(pods.get(0).getMetadata().getName()).getLog(), "");
        } catch (KubernetesClientException e) {
            // ContainerCreating answers 400 "waiting to start" — not an error, just nothing yet.
            if (e.getCode() == 400) {
                return "";
            }
            throw PortalException.upstream("the Kubernetes API (pod log)", e);
        }
    }

    private Job find(String name) {
        try {
            Job job = kubernetes.batch().v1().jobs().inNamespace(runner.namespace()).withName(name).get();
            if (job == null || job.getMetadata().getLabels() == null
                    || !PART_OF.equals(job.getMetadata().getLabels().get("app.kubernetes.io/part-of"))) {
                throw PortalException.notFound("no portal job named " + name);
            }
            return job;
        } catch (KubernetesClientException e) {
            throw PortalException.upstream("the Kubernetes API (get Job)", e);
        }
    }

    private static boolean isActive(String status) {
        return "PENDING".equals(status) || "RUNNING".equals(status);
    }

    private JobView view(Job job) {
        Map<String, String> labels = job.getMetadata().getLabels();
        String kindId = labels.getOrDefault(KIND_LABEL, "");
        Map<String, String> annotations = job.getMetadata().getAnnotations();
        String title = annotations != null && annotations.get(TITLE_ANNOTATION) != null
                ? annotations.get(TITLE_ANNOTATION)
                : Arrays.stream(JobKind.values()).filter(k -> k.id().equals(kindId)).map(JobKind::title).findFirst().orElse(kindId);
        JobStatus s = job.getStatus();
        String status = "PENDING";
        String finished = null;
        if (s != null) {
            if (s.getSucceeded() != null && s.getSucceeded() > 0) {
                status = "SUCCEEDED";
                finished = s.getCompletionTime();
            } else if (s.getFailed() != null && s.getFailed() > 0) {
                status = "FAILED";
                finished = failedAt(s);
            } else if (s.getActive() != null && s.getActive() > 0) {
                status = "RUNNING";
            }
        }
        String started = s != null && s.getStartTime() != null ? s.getStartTime() : job.getMetadata().getCreationTimestamp();
        return new JobView(job.getMetadata().getName(), kindId, title, labels.get(TARGET_LABEL), status,
                started, finished);
    }

    private static String failedAt(JobStatus s) {
        return s.getConditions() == null ? null : s.getConditions().stream()
                .filter(c -> "Failed".equals(c.getType()))
                .map(JobCondition::getLastTransitionTime).filter(Objects::nonNull)
                .findFirst().orElse(null);
    }
}
