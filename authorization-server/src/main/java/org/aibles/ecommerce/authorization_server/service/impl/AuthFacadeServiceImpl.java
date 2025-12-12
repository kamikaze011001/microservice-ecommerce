package org.aibles.ecommerce.authorization_server.service.impl;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.JWKSet;
import lombok.extern.slf4j.Slf4j;
import org.aibles.core_jwt_util.util.JwtUtil;
import org.aibles.ecommerce.authorization_server.constant.CacheConstant;
import org.aibles.ecommerce.authorization_server.constant.OTPType;
import org.aibles.ecommerce.authorization_server.dto.request.RegisterUserRequest;
import org.aibles.ecommerce.authorization_server.dto.request.ResetPasswordRequest;
import org.aibles.ecommerce.authorization_server.dto.response.LoginResponse;
import org.aibles.ecommerce.authorization_server.dto.response.RefreshTokenResponse;
import org.aibles.ecommerce.authorization_server.dto.response.VerifyForgotPasswordOtpResponse;
import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.exception.*;
import org.aibles.ecommerce.authorization_server.repository.projection.AccountUserProjection;
import org.aibles.ecommerce.authorization_server.service.*;
import org.aibles.ecommerce.authorization_server.util.GeneratorUtil;
import org.aibles.ecommerce.common_dto.exception.InternalErrorException;
import org.aibles.ecommerce.core_email.adapter.repository.EmailHelper;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.transaction.annotation.Transactional;

import java.text.ParseException;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

@Slf4j
public class AuthFacadeServiceImpl implements AuthFacadeService {

    private final AccountService accountService;

    private final UserService userService;

    private final RedisRepository redisRepository;

    private final EmailHelper emailHelper;

    private final PasswordEncoder passwordEncoder;

    private final JWTService jwtService;

    private final RoleService roleService;

    private final JWKSet jwkSet;

    public AuthFacadeServiceImpl(AccountService accountService, UserService userService, RedisRepository redisRepository, EmailHelper emailHelper, PasswordEncoder passwordEncoder, JWTService jwtService, RoleService roleService, JWKSet jwkSet) {
        this.accountService = accountService;
        this.userService = userService;
        this.redisRepository = redisRepository;
        this.emailHelper = emailHelper;
        this.passwordEncoder = passwordEncoder;
        this.jwtService = jwtService;
        this.roleService = roleService;
        this.jwkSet = jwkSet;
    }

    @Override
    @Transactional
    public void register(RegisterUserRequest request) {
        log.info("(register)email: {}, username: {}", request.getEmail(), request.getUsername());
        if (userService.isExistedByEmail(request.getEmail()) ||
                accountService.isExistedByUsername(request.getUsername())) {
            log.error("(register)email : {} or username: {} already existed", request.getEmail(), request.getUsername());
            throw new UserAlreadyExistedException();
        }
        try {
            User user = userService.save(request.getEmail());
            accountService.save(user.getId(), request.getUsername(), request.getPassword());
        } catch (DuplicateKeyException e) {
            log.error("(register)email or username : {}, {} already existed", request.getEmail(), request.getUsername(), e);
            throw new UserAlreadyExistedException();
        }
        String otp = GeneratorUtil.generateOtp();
        saveRedisAndSendMail(request.getEmail(), OTPType.ACTIVE_ACCOUNT, otp);
    }

    @Override
    @Transactional
    public void activate(String email, String otp) {
        log.info("(activate)email: {}", email);

        if (!userService.isExistedByEmail(email)) {
            log.error("(activate)email : {} does not exist", email);
            throw new EmailNotFoundException(email);
        }

        Optional<Object> otpOptional = redisRepository.get(email + CacheConstant.SEPARATOR_KEY + CacheConstant.Otp.ACTIVE_ACCOUNT);

        if (otpOptional.isEmpty()) {
            log.error("(activate)otp is expired");
            throw new OtpExpiredException();
        }

        String cacheOtp = (String) otpOptional.get();
        if (!otp.equals(cacheOtp)) {
            log.error("(activate)otp is incorrect");
            throw new OtpInvalidException();
        }

        accountService.activateByEmail(email);
    }

    @Override
    @Transactional(readOnly = true)
    public LoginResponse login(String username, String password) {
        log.info("(login)username: {}", username);
        AccountUserProjection accountUserPrj = accountService.findByUsername(username);

        if (accountUserPrj.getIsActivated().equals(Boolean.FALSE)) {
            log.error("(login)username {} is not activated", username);
            throw new AccountNotActivatedException();
        }

        if (!passwordEncoder.matches(password, accountUserPrj.getPassword())) {
            throw new PasswordInvalidException();
        }

        List<String> roles = accountService.getRolesById(accountUserPrj.getAccountId());
        String accessToken;
        String refreshToken;
        try {
            accessToken = jwtService.generateAccessToken(accountUserPrj.getUserId(), accountUserPrj.getEmail(), roles);
            refreshToken = jwtService.generateRefreshToken(accountUserPrj.getUserId(), accountUserPrj.getEmail());
        } catch (JOSEException ex) {
            log.error("(login)Error when generate tokens", ex);
            throw new InternalErrorException();
        }
        return LoginResponse.builder()
                .accessToken(accessToken)
                .refreshToken(refreshToken)
                .build();
    }

    @Override
    @Transactional
    public void updateRole(List<String> roleIds, String accountId) {
        log.info("(updateRole)roleIds: {}, accountId: {}", roleIds, accountId);
        if (!accountService.isExistedById(accountId)) {
            log.error("(updateRole)accountId : {} does not exist", accountId);
            throw new UserNotFoundException();
        }
        roleService.validateRoleList(roleIds);
        accountService.deleteRoles(accountId);
        accountService.addRoles(accountId, roleIds);
    }

    @Override
    @Transactional(readOnly = true)
    public RefreshTokenResponse refreshToken(String refreshToken) {
        if (Objects.isNull(refreshToken) || !refreshToken.startsWith("Bearer ")) {
            throw new TokenInvalidException();
        }

        refreshToken = refreshToken.substring(7);
        String userId;
        String email;
        try {
            if (!JwtUtil.verifyToken(jwkSet, refreshToken)) {
                throw new TokenInvalidException();
            }
            userId = JwtUtil.getSubjectFromToken(refreshToken);
            email = JwtUtil.getEmailFromToken(refreshToken);
        } catch (ParseException | JOSEException e) {
            throw new TokenInvalidException();
        }

        List<String> roles = accountService.getRolesByUserId(userId);

        String newAccessToken;
        String newRefreshToken;
        try {
            newAccessToken = jwtService.generateAccessToken(userId, email, roles);
            newRefreshToken = jwtService.generateRefreshToken(userId, email);
        } catch (JOSEException ex) {
            log.error("(login)Error when generate tokens", ex);
            throw new InternalErrorException();
        }

        return RefreshTokenResponse.builder()
                .accessToken(newAccessToken)
                .refreshToken(newRefreshToken)
                .build();
    }

    @Override
    @Transactional(readOnly = true)
    public void forgotPassword(String email) {
        log.info("(forgotPassword)email: {}", email);
        if (!userService.isExistedByEmail(email)) {
            log.error("(forgotPassword)email : {} does not exist", email);
            throw new EmailNotFoundException(email);
        }

        Optional<Object> otpOptional = redisRepository.get(email + CacheConstant.SEPARATOR_KEY + CacheConstant.Otp.FORGOT_PASSWORD);
        if (otpOptional.isPresent()) {
            log.error("(forgotPassword)otp is still in use");
            throw new OtpStillValidException();
        }

        String otp = GeneratorUtil.generateOtp();
        saveRedisAndSendMail(email, OTPType.FORGOT_PASSWORD, otp);
    }

    @Override
    @Transactional(readOnly = true)
    public VerifyForgotPasswordOtpResponse verifyForgotPasswordOtp(String email, String otp) {
        log.info("(verifyForgotPasswordOtp)email: {}, otp: {}", email, otp);
        if (!userService.isExistedByEmail(email)) {
            log.error("(verifyForgotPasswordOtp)email : {} does not exist", email);
            throw new EmailNotFoundException(email);
        }

        Optional<Object> otpOptional = redisRepository.get(email + CacheConstant.SEPARATOR_KEY + CacheConstant.Otp.FORGOT_PASSWORD);

        if (otpOptional.isEmpty()) {
            log.error("(verifyForgotPasswordOtp)otp : {} is expired", otp);
            throw new OtpExpiredException();
        }

        String cacheOtp = (String) otpOptional.get();
        if (!otp.equals(cacheOtp)) {
            log.error("(verifyForgotPasswordOtp)otp is incorrect");
            throw new OtpInvalidException();
        }

        String resetPassKey = GeneratorUtil.generateResetPassKey(email);
        redisRepository.save(CacheConstant.RESET_PASSWORD_KEY, email, resetPassKey);

        return VerifyForgotPasswordOtpResponse.builder()
                .resetPasswordKey(resetPassKey)
                .build();
    }

    @Override
    @Transactional
    public void resetPassword(ResetPasswordRequest request) {

        Optional<Object> otpOptional = redisRepository.get(CacheConstant.RESET_PASSWORD_KEY, request.getEmail());

        if (otpOptional.isEmpty()) {
            log.error("(resetPassword)reset password key is invalid");
            throw new InvalidResetPasswordKey();
        }

        String resetPassKey = (String) otpOptional.get();

        if (!resetPassKey.equals(request.getResetPasswordKey())) {
            throw new InvalidResetPasswordKey();
        }

        accountService.resetPasswordByEmail(request.getEmail(), request.getPassword());

        redisRepository.delete(CacheConstant.RESET_PASSWORD_KEY, request.getEmail());
    }

    @Override
    public void resendOtp(OTPType type, String email) {
        log.info("(resendOtp)type: {}, email: {}", type, email);

        if (!userService.isExistedByEmail(email)) {
            log.error("(resendOtp)email : {} does not exist", email);
            throw new EmailNotFoundException(email);
        }

        String otp = GeneratorUtil.generateOtp();

        saveRedisAndSendMail(email, type, otp);
    }

    private void saveRedisAndSendMail(String email, OTPType type, String otp) {
        redisRepository.save(email + CacheConstant.SEPARATOR_KEY + type.getRedisKey(),
                otp, type.getMinute(), TimeUnit.MINUTES);
        emailHelper.send(type.getMailSubject(), email,
                "Your otp is: " + otp + " and will expire in " + type.getMinute() + " minutes");
    }
}
