package org.aibles.ecommerce.authorization_server.filter;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.JWKSet;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.aibles.core_jwt_util.util.JwtUtil;
import org.aibles.ecommerce.authorization_server.exception.TokenInvalidException;
import org.springframework.http.HttpHeaders;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.text.ParseException;
import java.util.Collection;
import java.util.List;

@Component
@Slf4j
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JWKSet jwkSet;

    public JwtAuthenticationFilter(JWKSet jwkSet) {
        this.jwkSet = jwkSet;
    }


    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {
        log.info("(doFilterInternal)path: {}", request.getRequestURI());
        String authHeader = request.getHeader(HttpHeaders.AUTHORIZATION);
        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            filterChain.doFilter(request, response);
            return;
        }
        String token = authHeader.substring(7);
        try {
            if (!JwtUtil.verifyToken(jwkSet, token)) {
                throw new TokenInvalidException();
            }

            String userId = JwtUtil.getSubjectFromToken(token);
            String email = JwtUtil.getEmailFromToken(token);
            Collection<SimpleGrantedAuthority> roles = from(JwtUtil.getRolesFromToken(token));
            UsernamePasswordAuthenticationToken upat = new UsernamePasswordAuthenticationToken(userId, email, roles);

            if (SecurityContextHolder.getContext().getAuthentication() == null) {
                SecurityContextHolder.getContext().setAuthentication(upat);
            }

            filterChain.doFilter(request, response);
        } catch (ParseException | JOSEException ex) {
            log.error("(doFilterInternal)Token is invalid");
            throw new TokenInvalidException();
        }
    }

    private Collection<SimpleGrantedAuthority> from(List<String> roles) {
        return roles.stream().map(SimpleGrantedAuthority::new).toList();
    }
}
