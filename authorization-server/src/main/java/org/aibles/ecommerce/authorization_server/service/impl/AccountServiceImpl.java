package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.entity.Account;
import org.aibles.ecommerce.authorization_server.entity.AccountRole;
import org.aibles.ecommerce.authorization_server.exception.EmailNotFoundException;
import org.aibles.ecommerce.authorization_server.exception.OldPasswordInvalidException;
import org.aibles.ecommerce.authorization_server.exception.UserNotFoundException;
import org.aibles.ecommerce.authorization_server.repository.AccountRepository;
import org.aibles.ecommerce.authorization_server.repository.AccountRoleRepository;
import org.aibles.ecommerce.authorization_server.repository.projection.AccountUserProjection;
import org.aibles.ecommerce.authorization_server.service.AccountService;
import org.aibles.ecommerce.authorization_server.service.RefreshTokenService;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

@Slf4j
public class AccountServiceImpl implements AccountService {

    private final AccountRepository accountRepository;

    private final AccountRoleRepository accountRoleRepository;

    private final PasswordEncoder passwordEncoder;

    private final RefreshTokenService refreshTokenService;

    public AccountServiceImpl(AccountRepository accountRepository, AccountRoleRepository accountRoleRepository, PasswordEncoder passwordEncoder, RefreshTokenService refreshTokenService) {
        this.accountRepository = accountRepository;
        this.accountRoleRepository = accountRoleRepository;
        this.passwordEncoder = passwordEncoder;
        this.refreshTokenService = refreshTokenService;
    }

    @Override
    @Transactional(readOnly = true)
    public boolean isExistedByUsername(String username) {
        log.info("(isExistedByUsername)username: {}", username);
        return accountRepository.existsByUsername(username);
    }

    @Override
    @Transactional
    public void save(String userId, String username, String password) {
        log.info("(save)username: {}", username);
        password = passwordEncoder.encode(password);
        Account account = Account.builder()
                .userId(userId)
                .username(username)
                .password(password)
                .isActivated(false)
                .build();
        accountRepository.save(account);
    }

    @Override
    @Transactional
    public void activateByEmail(String email) {
        log.info("(activateByEmail)email: {}", email);

        Optional<Account> accountOptional = accountRepository.findbyEmail(email);
        if (accountOptional.isEmpty()) {
            throw new EmailNotFoundException(email);
        }
        Account account = accountOptional.get();
        account.setIsActivated(true);
        accountRepository.save(account);
    }

    @Override
    @Transactional(readOnly = true)
    public AccountUserProjection findByUsername(String username) {
        log.info("(findByUsername)username: {}", username);
        Optional<AccountUserProjection> accountUserOptional = accountRepository.findByUsername(username);
        if (accountUserOptional.isEmpty()) {
            throw new UserNotFoundException();
        }
        return accountUserOptional.get();
    }

    @Override
    @Transactional(readOnly = true)
    public List<String> getRolesById(String id) {
        log.info("(getRolesById)id : {}", id);
        return accountRepository.findRolesById(id);
    }

    @Override
    @Transactional(readOnly = true)
    public List<String> getRolesByUserId(String userId) {
        log.info("(getRolesByUserId)userId : {}", userId);
        return accountRepository.findRolesByUserId(userId);
    }

    @Override
    @Transactional
    public void deleteRoles(String id) {
        log.info("(deleteRoles)id : {}", id);
        accountRepository.deleteRolesById(id);
    }

    @Override
    @Transactional
    public void addRoles(String accountId, List<String> roles) {
        log.info("(addRoles)accountId: {}, rolesIds : {}", accountId, roles);
        List<AccountRole> accountRoles = new ArrayList<>();
        AccountRole accountRole;
        for (String role : roles) {
            accountRole = AccountRole.builder()
                    .accountId(accountId)
                    .roleId(role)
                    .build();
            accountRoles.add(accountRole);
        }
        accountRoleRepository.saveAll(accountRoles);
    }

    @Override
    @Transactional(readOnly = true)
    public boolean isExistedById(String id) {
        log.info("(isExistedById)id : {}", id);
        return accountRepository.existsById(id);
    }

    @Override
    @Transactional
    public void resetPasswordByEmail(String email, String newPassword) {
        String encodedPassword = passwordEncoder.encode(newPassword);
        accountRepository.resetPasswordByEmail(email, encodedPassword);
    }

    @Override
    @Transactional
    public void updatePassword(String userId, String oldPassword, String newPassword) {

        Account account = accountRepository.findByUserId(userId).orElseThrow(UserNotFoundException::new);

        if (!passwordEncoder.matches(oldPassword, account.getPassword())) {
            throw new OldPasswordInvalidException();
        }

        account.setPassword(passwordEncoder.encode(newPassword));

        accountRepository.save(account);

        log.info("revoked all refresh-token families on password change. userId={}", userId);
        refreshTokenService.revokeAllForUser(userId);
    }

    @Override
    @Transactional(readOnly = true)
    public String getUserIdByEmail(String email) {
        return accountRepository.findUserIdByEmail(email)
                .orElseThrow(() -> new EmailNotFoundException(email));
    }
}
