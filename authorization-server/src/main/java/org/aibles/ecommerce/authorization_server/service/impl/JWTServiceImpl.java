package org.aibles.ecommerce.authorization_server.service.impl;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.JWSSigner;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import lombok.extern.slf4j.Slf4j;
import org.aibles.core_jwt_util.constant.JwtConstant;
import org.aibles.ecommerce.authorization_server.service.JWTService;

import java.util.ArrayList;
import java.util.Date;
import java.util.List;

@Slf4j
public class JWTServiceImpl implements JWTService {

    private final JWKSet jwkSet;

    private final Integer accessTokenLifetime;

    private final Integer refreshTokenLifetime;

    public JWTServiceImpl(JWKSet jwkSet, Integer accessTokenLifetime, Integer refreshTokenLifetime) {
        this.jwkSet = jwkSet;
        this.accessTokenLifetime = accessTokenLifetime;
        this.refreshTokenLifetime = refreshTokenLifetime;
    }

    @Override
    public String generateAccessToken(String subject, String email, List<String> roles) throws JOSEException {
        log.info("(generateAccessToken)subject : {}", subject);
        return generateToken(subject, email, roles, accessTokenLifetime);
    }

    @Override
    public String generateRefreshToken(String subject, String email) throws JOSEException {
        log.info("(generateRefreshToken)subject : {}", subject);
        return generateToken(subject, email, new ArrayList<>(), refreshTokenLifetime);
    }

    private String generateToken(String subject, String email, List<String> roles, Integer lifetime) throws JOSEException {
        log.info("(generateToken)subject : {}", subject);
        RSAKey rsaKey = (RSAKey) jwkSet.getKeys().get(0);
        JWSSigner signer = new RSASSASigner(rsaKey.toPrivateKey());

        JWTClaimsSet claimsSet = new JWTClaimsSet.Builder()
                .subject(subject)
                .claim(JwtConstant.ClaimKey.EMAIL, email)
                .claim(JwtConstant.ClaimKey.ROLES, roles.isEmpty() ? new ArrayList<>() : roles)
                .expirationTime(new Date(System.currentTimeMillis() + lifetime))
                .build();

        SignedJWT signedJWT = new SignedJWT(
                new JWSHeader.Builder(JWSAlgorithm.RS256)
                        .keyID(rsaKey.getKeyID())
                        .build(),
                claimsSet
        );

        signedJWT.sign(signer);

        return signedJWT.serialize();
    }
}
