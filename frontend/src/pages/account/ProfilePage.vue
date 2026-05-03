<script setup lang="ts">
import { ref, watch } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import {
  useProfileQuery,
  useUpdateProfileMutation,
  useChangePasswordMutation,
  useAvatarPresignMutation,
  useAttachAvatarMutation,
} from '@/api/queries/profile';
import { profileSchema, changePasswordSchema } from '@/lib/zod-schemas';
import { useToast } from '@/composables/useToast';
import { BButton, BCard, BInput, BSelect, type BSelectOption } from '@/components/primitives';
import BImageFallback from '@/components/BImageFallback.vue';

const toast = useToast();
const profile = useProfileQuery();
const updateM = useUpdateProfileMutation();
const passwordM = useChangePasswordMutation();
const presignM = useAvatarPresignMutation();
const attachM = useAttachAvatarMutation();

// ── Section 02 — COLOPHON (profile form) ─────────────────────────────────────
const {
  handleSubmit: handleProfileSubmit,
  errors: profileErrors,
  defineField: defineProfileField,
  resetForm: resetProfileForm,
} = useForm({
  validationSchema: toTypedSchema(profileSchema),
  initialValues: { name: '', gender: null as 'MALE' | 'FEMALE' | 'OTHER' | null, address: '' },
});

const [profileName, profileNameAttrs] = defineProfileField('name');
const [profileGender, profileGenderAttrs] = defineProfileField('gender');
const [profileAddress, profileAddressAttrs] = defineProfileField('address');

// Seed form when profile loads
watch(
  () => profile.data.value,
  (data) => {
    if (!data) return;
    resetProfileForm({
      values: {
        name: data.name ?? '',
        gender: data.gender ?? null,
        address: data.address ?? '',
      },
    });
  },
  { immediate: true },
);

const profileSubmitting = ref(false);
const onProfileSubmit = handleProfileSubmit(async (values) => {
  profileSubmitting.value = true;
  try {
    await updateM.mutateAsync({
      name: values.name,
      gender: values.gender,
      address: values.address || null,
    });
    toast.success('PROFILE UPDATED');
  } catch {
    toast.error('UPDATE MISFIRE');
  } finally {
    profileSubmitting.value = false;
  }
});

const genderOptions: BSelectOption[] = [
  { value: 'MALE', label: 'MALE' },
  { value: 'FEMALE', label: 'FEMALE' },
  { value: 'OTHER', label: 'OTHER' },
];

// ── Section 03 — CREDENTIALS (change password) ───────────────────────────────
const {
  handleSubmit: handlePasswordSubmit,
  errors: passwordErrors,
  defineField: definePasswordField,
  resetForm: resetPasswordForm,
} = useForm({
  validationSchema: toTypedSchema(changePasswordSchema),
  initialValues: { oldPassword: '', newPassword: '', confirmNewPassword: '' },
});

const [oldPassword, oldPasswordAttrs] = definePasswordField('oldPassword');
const [newPassword, newPasswordAttrs] = definePasswordField('newPassword');
const [confirmNewPassword, confirmNewPasswordAttrs] = definePasswordField('confirmNewPassword');

const passwordSubmitting = ref(false);
const onPasswordSubmit = handlePasswordSubmit(async (values) => {
  passwordSubmitting.value = true;
  try {
    await passwordM.mutateAsync({
      old_password: values.oldPassword,
      new_password: values.newPassword,
      confirm_new_password: values.confirmNewPassword,
    });
    toast.success('PASSWORD CHANGED');
    resetPasswordForm();
  } catch {
    toast.error('WRONG CURRENT PASSWORD');
  } finally {
    passwordSubmitting.value = false;
  }
});

// ── Section 01 — MASTHEAD (avatar upload) ────────────────────────────────────
const fileInputRef = ref<HTMLInputElement | null>(null);
const avatarUploading = ref(false);
const avatarError = ref<string | null>(null);

async function onFileChange(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0];
  if (!file) return;
  avatarError.value = null;
  avatarUploading.value = true;
  try {
    const presign = await presignM.mutateAsync({
      content_type: file.type,
      size_bytes: file.size,
    });
    // PUT directly to S3 presigned URL
    const putRes = await fetch(presign.upload_url, {
      method: 'PUT',
      body: file,
      headers: { 'Content-Type': file.type },
    });
    if (!putRes.ok) throw new Error('UPLOAD MISFIRE');
    await attachM.mutateAsync({ object_key: presign.object_key });
    toast.success('AVATAR REPLACED');
  } catch {
    avatarError.value = 'UPLOAD MISFIRE';
    toast.error('UPLOAD MISFIRE');
  } finally {
    avatarUploading.value = false;
    if (fileInputRef.value) fileInputRef.value.value = '';
  }
}
</script>

<template>
  <div class="profile">
    <!-- ── 01 — MASTHEAD ──────────────────────────────────────────────────── -->
    <section class="profile__section" aria-label="Avatar">
      <header class="profile__section-head">
        <span class="profile__numeral" aria-hidden="true">01</span>
        <p class="profile__kicker">MASTHEAD</p>
      </header>

      <BCard as="div" class="profile__card">
        <div class="profile__avatar-row">
          <div class="profile__avatar-wrap">
            <img
              v-if="profile.data.value?.avatar_url"
              :src="profile.data.value.avatar_url"
              :alt="profile.data.value?.name ?? 'Avatar'"
              class="profile__avatar-img"
            />
            <BImageFallback
              v-else
              :name="profile.data.value?.name ?? 'AVATAR'"
              class="profile__avatar-fallback"
            />
          </div>

          <div class="profile__avatar-controls">
            <p class="profile__display-name">{{ profile.data.value?.name ?? '—' }}</p>
            <p class="profile__email">{{ profile.data.value?.email ?? '—' }}</p>

            <!-- hidden file input -->
            <input
              ref="fileInputRef"
              type="file"
              accept="image/png,image/jpeg,image/webp"
              class="profile__file-input"
              tabindex="-1"
              aria-label="Upload avatar"
              @change="onFileChange"
            />
            <BButton variant="spot" :loading="avatarUploading" @click="fileInputRef?.click()">
              CHANGE PHOTO
            </BButton>
            <p v-if="avatarError" class="profile__inline-error">{{ avatarError }}</p>
          </div>
        </div>
      </BCard>
    </section>

    <!-- ── 02 — COLOPHON ─────────────────────────────────────────────────── -->
    <section class="profile__section" aria-label="Profile details">
      <header class="profile__section-head">
        <span class="profile__numeral" aria-hidden="true">02</span>
        <p class="profile__kicker">COLOPHON</p>
      </header>

      <BCard as="div" class="profile__card">
        <form novalidate @submit.prevent="onProfileSubmit">
          <div class="profile__fields">
            <BInput
              :model-value="profileName ?? ''"
              v-bind="profileNameAttrs"
              label="NAME"
              :error="profileErrors.name"
              @update:model-value="profileName = $event"
            />

            <!-- Gender select with label -->
            <div class="profile__field-group">
              <label class="profile__field-label" for="gender-select">GENDER</label>
              <BSelect
                id="gender-select"
                :model-value="profileGender ?? ''"
                v-bind="profileGenderAttrs"
                :options="genderOptions"
                placeholder="SELECT GENDER"
                :error="profileErrors.gender"
                @update:model-value="
                  profileGender = ($event as 'MALE' | 'FEMALE' | 'OTHER') || null
                "
              />
              <p v-if="profileErrors.gender" class="profile__inline-error">
                {{ profileErrors.gender }}
              </p>
            </div>

            <!-- Email — read only -->
            <BInput :model-value="profile.data.value?.email ?? ''" label="EMAIL" disabled />

            <!-- Address textarea -->
            <div class="profile__field-group">
              <label class="profile__field-label" for="address-textarea">ADDRESS</label>
              <textarea
                id="address-textarea"
                v-model="profileAddress"
                v-bind="profileAddressAttrs"
                class="profile__textarea"
                :class="{ 'has-error': !!profileErrors.address }"
                rows="3"
                placeholder="Optional shipping address"
              />
              <p v-if="profileErrors.address" class="profile__inline-error">
                {{ profileErrors.address }}
              </p>
            </div>
          </div>

          <div class="profile__form-footer">
            <BButton
              type="submit"
              variant="spot"
              :loading="profileSubmitting"
              :disabled="profileSubmitting"
            >
              SAVE COLOPHON
            </BButton>
          </div>
        </form>
      </BCard>
    </section>

    <!-- ── 03 — CREDENTIALS ───────────────────────────────────────────────── -->
    <section class="profile__section" aria-label="Change password">
      <header class="profile__section-head">
        <span class="profile__numeral" aria-hidden="true">03</span>
        <p class="profile__kicker">CREDENTIALS</p>
      </header>

      <BCard as="div" class="profile__card">
        <form novalidate @submit.prevent="onPasswordSubmit">
          <div class="profile__fields">
            <BInput
              :model-value="oldPassword ?? ''"
              v-bind="oldPasswordAttrs"
              label="CURRENT PASSWORD"
              type="password"
              :error="passwordErrors.oldPassword"
              @update:model-value="oldPassword = $event"
            />
            <BInput
              :model-value="newPassword ?? ''"
              v-bind="newPasswordAttrs"
              label="NEW PASSWORD"
              type="password"
              :error="passwordErrors.newPassword"
              @update:model-value="newPassword = $event"
            />
            <BInput
              :model-value="confirmNewPassword ?? ''"
              v-bind="confirmNewPasswordAttrs"
              label="CONFIRM NEW PASSWORD"
              type="password"
              :error="passwordErrors.confirmNewPassword"
              @update:model-value="confirmNewPassword = $event"
            />
          </div>

          <div class="profile__form-footer">
            <BButton
              type="submit"
              variant="ink"
              :loading="passwordSubmitting"
              :disabled="passwordSubmitting"
            >
              CHANGE PASSWORD
            </BButton>
          </div>
        </form>
      </BCard>
    </section>
  </div>
</template>

<style scoped>
.profile {
  display: flex;
  flex-direction: column;
  gap: var(--space-10);
  max-width: 720px;
  margin: 0 auto;
  padding: var(--space-6) 0;
}

/* ── Section header ─────────────────────────────────────────────────────────── */
.profile__section-head {
  display: flex;
  align-items: baseline;
  gap: var(--space-3);
  border-bottom: var(--border-thin);
  padding-bottom: var(--space-2);
  margin-bottom: var(--space-4);
}

.profile__numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-h1);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}

.profile__kicker {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}

/* ── Card ───────────────────────────────────────────────────────────────────── */
.profile__card {
  width: 100%;
}

/* ── Avatar row ─────────────────────────────────────────────────────────────── */
.profile__avatar-row {
  display: flex;
  align-items: center;
  gap: var(--space-6);
}

.profile__avatar-wrap {
  width: 6rem;
  height: 6rem;
  flex-shrink: 0;
  overflow: hidden;
  border: var(--border-thick);
}

.profile__avatar-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.profile__avatar-fallback {
  width: 100%;
  height: 100%;
}

.profile__avatar-controls {
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
}

.profile__display-name {
  font-family: var(--font-display);
  font-weight: 800;
  font-size: var(--type-h3);
  text-transform: uppercase;
  margin: 0;
}

.profile__email {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  color: var(--muted-ink);
  margin: 0;
}

.profile__file-input {
  position: absolute;
  width: 1px;
  height: 1px;
  opacity: 0;
  pointer-events: none;
}

/* ── Fields ─────────────────────────────────────────────────────────────────── */
.profile__fields {
  display: flex;
  flex-direction: column;
  gap: var(--space-4);
}

.profile__field-group {
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
}

.profile__field-label {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.profile__textarea {
  border: var(--border-thick);
  background: var(--paper);
  padding: var(--space-3);
  font-family: var(--font-body);
  font-size: var(--type-body);
  color: var(--ink);
  resize: vertical;
  transition:
    transform var(--transition-snap),
    outline-color var(--transition-snap);
}

.profile__textarea:focus {
  outline: 2px solid var(--spot);
  outline-offset: 2px;
  transform: translate(2px, 0);
}

.profile__textarea.has-error {
  border-color: var(--stamp-red);
}

.profile__inline-error {
  color: var(--stamp-red);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  margin: 0;
}

/* ── Footer ─────────────────────────────────────────────────────────────────── */
.profile__form-footer {
  margin-top: var(--space-6);
  display: flex;
  justify-content: flex-end;
}
</style>
