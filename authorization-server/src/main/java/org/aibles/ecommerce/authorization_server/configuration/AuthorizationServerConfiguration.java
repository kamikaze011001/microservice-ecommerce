package org.aibles.ecommerce.authorization_server.configuration;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.KeyUse;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import org.aibles.ecommerce.authorization_server.repository.master.MasterAccountRepository;
import org.aibles.ecommerce.authorization_server.repository.master.MasterAccountRoleRepository;
import org.aibles.ecommerce.authorization_server.repository.master.MasterUserRepository;
import org.aibles.ecommerce.authorization_server.repository.slave.SlaveAccountRepository;
import org.aibles.ecommerce.authorization_server.repository.slave.SlaveRoleRepository;
import org.aibles.ecommerce.authorization_server.repository.slave.SlaveUserRepository;
import org.aibles.ecommerce.authorization_server.service.*;
import org.aibles.ecommerce.authorization_server.service.impl.*;
import org.aibles.ecommerce.core_email.adapter.repository.EmailHelper;
import org.aibles.ecommerce.core_email.framework.configuration.EnableCoreEmail;
import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_routing_db.configuration.EnableDatasourceRouting;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

@EnableCoreRedis
@EnableDatasourceRouting
@EnableCoreEmail
@EnableCoreExceptionApi
@Configuration
@EnableJpaAuditing
public class AuthorizationServerConfiguration {

    @Value("${application.access-token.life-time}")
    private Integer accessTokenLifetime;

    @Value("${application.refresh-token.life-time}")
    private Integer refreshTokenLifetime;

    @Value("${application.authentication-key-id}")
    private String secretKey;

    @Bean
    public JWKSet jwkSet() throws JOSEException {
        RSAKey rsaKey = new RSAKeyGenerator(2048)
                .keyUse(KeyUse.SIGNATURE)
                .algorithm(JWSAlgorithm.RS256)
                .keyID(secretKey)
                .generate();
        return new JWKSet(rsaKey);
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    public UserService userService(MasterUserRepository masterUserRepository, SlaveUserRepository slaveUserRepository) {
        return new UserServiceImpl(masterUserRepository, slaveUserRepository);
    }

    @Bean
    public AccountService accountService(MasterAccountRepository masterAccountRepository,
                                         SlaveAccountRepository slaveAccountRepository,
                                         MasterAccountRoleRepository masterAccountRoleRepository,
                                         PasswordEncoder passwordEncoder) {
        return new AccountServiceImpl(masterAccountRepository, slaveAccountRepository, masterAccountRoleRepository, passwordEncoder);
    }

    @Bean
    public RoleService roleService(SlaveRoleRepository slaveRoleRepository) {
        return new RoleServiceImpl(slaveRoleRepository);
    }

    @Bean
    public JWTService jwtService(JWKSet jwkSet) {
        return new JWTServiceImpl(jwkSet, accessTokenLifetime, refreshTokenLifetime);
    }

    @Bean
    public AuthFacadeService authFacadeService(AccountService accountService,
                                               UserService userService,
                                               RedisRepository redisRepository,
                                               EmailHelper emailHelper,
                                               PasswordEncoder passwordEncoder,
                                               JWTService jwtService,
                                               RoleService roleService,
                                               JWKSet jwkSet) {
        return new AuthFacadeServiceImpl(accountService, userService, redisRepository, emailHelper, passwordEncoder, jwtService, roleService, jwkSet);
    }
}
