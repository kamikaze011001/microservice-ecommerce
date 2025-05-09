package org.aibles.ecommerce.authorization_server.service;

import com.nimbusds.jose.JOSEException;

import java.util.List;

public interface JWTService {

    String generateAccessToken(String subject, String email, List<String> roles) throws JOSEException;

    String generateRefreshToken(String subject, String email) throws JOSEException;
}
