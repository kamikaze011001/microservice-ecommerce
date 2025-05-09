package org.aibles.core_jwt_util.util;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSVerifier;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jose.jwk.JWK;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import lombok.extern.slf4j.Slf4j;
import org.aibles.core_jwt_util.constant.JwtConstant;

import java.text.ParseException;
import java.util.Date;
import java.util.List;
import java.util.Map;

@Slf4j
public class JwtUtil {

    private JwtUtil() {}

    public static String getSubjectFromToken(String token) throws ParseException {
        log.info("(getSubjectFromToken)token : {}", token);
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return claimsSet.getSubject();
    }

    public static String getEmailFromToken(String token) throws ParseException {
        log.info("(getEmailFromToken)token : {}", token);
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return (String) claimsSet.getClaim(JwtConstant.ClaimKey.EMAIL);
    }

    public static List<String> getRolesFromToken(String token) throws ParseException {
        log.info("(getRolesFromToken)token : {}", token);
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return (List<String>) claimsSet.getClaim(JwtConstant.ClaimKey.ROLES);
    }

    public static Map<String, Object> getClaimsFromToken(String token) throws ParseException {
        log.info("(getClaimsFromToken)token : {}", token);
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return claimsSet.getClaims();
    }

    public static boolean verifyToken(JWKSet jwkSet, String token) throws ParseException, JOSEException {
        log.info("(verifyToken)token : {}", token);
        SignedJWT signedJWT = SignedJWT.parse(token);
        String kid = signedJWT.getHeader().getKeyID();
        JWK jwk = jwkSet.getKeyByKeyId(kid);
        if (!(jwk instanceof RSAKey rsaKey)) {
            return false;
        }

        JWSVerifier verifier = new RSASSAVerifier(rsaKey.toRSAPublicKey());

        if (!signedJWT.verify(verifier)) {
            return false;
        }

        Date expirationTime = signedJWT.getJWTClaimsSet().getExpirationTime();

        return !new Date().after(expirationTime);
    }
}
