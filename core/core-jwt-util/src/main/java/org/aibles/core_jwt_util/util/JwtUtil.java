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
import org.aibles.core_jwt_util.dto.TokenClaims;

import java.text.ParseException;
import java.util.Date;
import java.util.List;
import java.util.Map;

@Slf4j
public class JwtUtil {

    private JwtUtil() {}

    /**
     * SECURITY FIX: Removed token logging to prevent sensitive data exposure
     */
    public static String getSubjectFromToken(String token) throws ParseException {
        log.debug("(getSubjectFromToken) Extracting subject from token");
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return claimsSet.getSubject();
    }

    /**
     * SECURITY FIX: Removed token logging to prevent sensitive data exposure
     */
    public static String getEmailFromToken(String token) throws ParseException {
        log.debug("(getEmailFromToken) Extracting email from token");
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return (String) claimsSet.getClaim(JwtConstant.ClaimKey.EMAIL);
    }

    /**
     * SECURITY FIX: Removed token logging to prevent sensitive data exposure
     */
    public static List<String> getRolesFromToken(String token) throws ParseException {
        log.debug("(getRolesFromToken) Extracting roles from token");
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return (List<String>) claimsSet.getClaim(JwtConstant.ClaimKey.ROLES);
    }

    /**
     * SECURITY FIX: Removed token logging to prevent sensitive data exposure
     */
    public static Map<String, Object> getClaimsFromToken(String token) throws ParseException {
        log.debug("(getClaimsFromToken) Extracting all claims from token");
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        return claimsSet.getClaims();
    }

    /**
     * PERFORMANCE OPTIMIZATION: Extracts all claims in a single token parse operation.
     * Use this instead of calling getSubjectFromToken, getEmailFromToken, and getRolesFromToken separately.
     *
     * @param token JWT token string
     * @return TokenClaims object containing userId, email, and roles
     * @throws ParseException if token cannot be parsed
     */
    public static TokenClaims extractAllClaims(String token) throws ParseException {
        log.debug("(extractAllClaims) Extracting all claims from token in single pass");
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();

        return TokenClaims.builder()
                .userId(claimsSet.getSubject())
                .email((String) claimsSet.getClaim(JwtConstant.ClaimKey.EMAIL))
                .roles((List<String>) claimsSet.getClaim(JwtConstant.ClaimKey.ROLES))
                .build();
    }

    /**
     * PERFORMANCE OPTIMIZATION: Verifies token and extracts all claims in a single operation.
     * This is the most efficient method for authentication as it combines verification and extraction.
     *
     * @param jwkSet JWK Set for verification
     * @param token JWT token string
     * @return TokenClaims object if token is valid, null if token is invalid or expired
     * @throws ParseException if token cannot be parsed
     * @throws JOSEException if there's an error during signature verification
     */
    public static TokenClaims verifyAndExtractClaims(JWKSet jwkSet, String token) throws ParseException, JOSEException {
        log.debug("(verifyAndExtractClaims) Verifying and extracting claims in single pass");

        SignedJWT signedJWT = SignedJWT.parse(token);

        // Verify signature
        String kid = signedJWT.getHeader().getKeyID();
        JWK jwk = jwkSet.getKeyByKeyId(kid);
        if (!(jwk instanceof RSAKey rsaKey)) {
            log.warn("(verifyAndExtractClaims) Invalid key type for kid: {}", kid);
            return null;
        }

        JWSVerifier verifier = new RSASSAVerifier(rsaKey.toRSAPublicKey());
        if (!signedJWT.verify(verifier)) {
            log.warn("(verifyAndExtractClaims) Signature verification failed");
            return null;
        }

        // Check expiration
        JWTClaimsSet claimsSet = signedJWT.getJWTClaimsSet();
        Date expirationTime = claimsSet.getExpirationTime();
        if (new Date().after(expirationTime)) {
            log.debug("(verifyAndExtractClaims) Token is expired");
            return null;
        }

        // Extract all claims
        return TokenClaims.builder()
                .userId(claimsSet.getSubject())
                .email((String) claimsSet.getClaim(JwtConstant.ClaimKey.EMAIL))
                .roles((List<String>) claimsSet.getClaim(JwtConstant.ClaimKey.ROLES))
                .build();
    }

    /**
     * SECURITY FIX: Removed token logging to prevent sensitive data exposure
     * NOTE: Consider using verifyAndExtractClaims() for better performance if you need claims after verification
     */
    public static boolean verifyToken(JWKSet jwkSet, String token) throws ParseException, JOSEException {
        log.debug("(verifyToken) Verifying token");
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
