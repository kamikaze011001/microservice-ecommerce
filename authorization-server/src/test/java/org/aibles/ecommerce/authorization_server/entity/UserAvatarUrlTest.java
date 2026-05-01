package org.aibles.ecommerce.authorization_server.entity;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class UserAvatarUrlTest {

    @Test
    void userHasNullableAvatarUrl() {
        User u = new User();
        u.setAvatarUrl("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
        assertThat(u.getAvatarUrl()).isEqualTo("http://localhost:9000/ecommerce-media/avatars/u1/x.png");

        User noAvatar = new User();
        assertThat(noAvatar.getAvatarUrl()).isNull();
    }
}
