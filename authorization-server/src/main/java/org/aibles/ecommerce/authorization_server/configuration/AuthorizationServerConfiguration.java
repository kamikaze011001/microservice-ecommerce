package org.aibles.ecommerce.authorization_server.configuration;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.KeyUse;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import java.text.ParseException;
import org.aibles.ecommerce.authorization_server.repository.AccountRepository;
import org.aibles.ecommerce.authorization_server.repository.AccountRoleRepository;
import org.aibles.ecommerce.authorization_server.repository.UserRepository;
import org.aibles.ecommerce.authorization_server.repository.RoleRepository;
import org.aibles.ecommerce.authorization_server.service.*;
import org.aibles.ecommerce.authorization_server.service.impl.*;
import org.aibles.ecommerce.core_email.adapter.repository.EmailHelper;
import org.aibles.ecommerce.core_email.framework.configuration.EnableCoreEmail;
import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_replica_routing.EnableReplicaRouting;
import org.aibles.ecommerce.core_s3.EnableCoreS3;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

@EnableCoreRedis
@EnableReplicaRouting
@EnableCoreEmail
@EnableCoreExceptionApi
@EnableCoreS3
@Configuration
@EnableJpaAuditing
public class AuthorizationServerConfiguration {

    @Value("${application.access-token.life-time}")
    private Integer accessTokenLifetime;

    @Value("${application.refresh-token.life-time}")
    private Integer refreshTokenLifetime;

    @Value("${application.authentication-key-id}")
    private String secretKey;

    @Value("${application.jwk}")
    private String jwkJson;

    @Bean
    public JWKSet jwkSet() throws ParseException {
        // Load a STABLE signing key from Vault (application.jwk) rather than
        // generating one per startup. A per-pod generated key invalidated all
        // live tokens on every restart (the gateway caches JWKS by kid, which is
        // constant here) and made the auth tier impossible to scale: each replica
        // would sign with a different key under the same kid, so the gateway's
        // cached JWKS validated only one replica's tokens. The kid/use/alg are
        // embedded in the JWK JSON.
        return new JWKSet(RSAKey.parse(jwkJson));
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    public UserService userService(UserRepository userRepository) {
        return new UserServiceImpl(userRepository);
    }

    @Bean
    public AccountService accountService(AccountRepository accountRepository,
                                         AccountRoleRepository accountRoleRepository,
                                         PasswordEncoder passwordEncoder,
                                         RefreshTokenService refreshTokenService) {
        return new AccountServiceImpl(accountRepository, accountRoleRepository, passwordEncoder, refreshTokenService);
    }

    @Bean
    public RoleService roleService(RoleRepository roleRepository) {
        return new RoleServiceImpl(roleRepository);
    }

    @Bean
    public RefreshTokenService refreshTokenService(RedisTemplate<String, Object> redisTemplate) {
        return new RefreshTokenServiceImpl(redisTemplate, refreshTokenLifetime.longValue());
    }

    @Bean
    public JWTService jwtService(JWKSet jwkSet) {
        return new JWTServiceImpl(jwkSet, accessTokenLifetime, refreshTokenLifetime);
    }

    @Bean
    public UserAvatarService userAvatarService(UserRepository userRepository,
                                               S3StorageService storage,
                                               S3Properties props) {
        return new UserAvatarServiceImpl(userRepository, storage, props);
    }

    @Bean
    public AuthFacadeService authFacadeService(AccountService accountService,
                                               UserService userService,
                                               RedisRepository redisRepository,
                                               EmailHelper emailHelper,
                                               PasswordEncoder passwordEncoder,
                                               JWTService jwtService,
                                               RoleService roleService,
                                               RefreshTokenService refreshTokenService) {
        return new AuthFacadeServiceImpl(accountService, userService, redisRepository, emailHelper, passwordEncoder, jwtService, roleService, refreshTokenService);
    }
}
