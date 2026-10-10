package org.aibles.ecommerce.devbox_portal.service;

import org.aibles.ecommerce.devbox_portal.dto.PortalViews.SettingsResult;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.SettingsView;

import java.util.Map;

/** A service's per-env settings (Spring properties + env vars), edited as commits to the env repo. */
public interface SettingsService {

    SettingsView get(String env, String service);

    /** {@code baseSha}: the file version the page edited; a newer one is a 409, never an overwrite. */
    SettingsResult save(String env, String service, Map<String, String> spring, Map<String, String> envVars, String baseSha);

    /** Put the settings back to how they were just before {@code commit} (the image tag is left alone). */
    SettingsResult revert(String env, String service, String commit);
}
