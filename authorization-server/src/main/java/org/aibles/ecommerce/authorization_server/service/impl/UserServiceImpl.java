package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.constant.Gender;
import org.aibles.ecommerce.authorization_server.dto.request.FilterRequest;
import org.aibles.ecommerce.authorization_server.dto.request.UpdateUserRequest;
import org.aibles.ecommerce.authorization_server.dto.response.UserDetailResponse;
import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.exception.UserNotFoundException;
import org.aibles.ecommerce.authorization_server.repository.master.MasterUserRepository;
import org.aibles.ecommerce.authorization_server.repository.slave.SlaveUserRepository;
import org.aibles.ecommerce.authorization_server.service.UserService;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Slf4j
public class UserServiceImpl implements UserService {

    private final MasterUserRepository masterUserRepository;

    private final SlaveUserRepository slaveUserRepository;

    public UserServiceImpl(MasterUserRepository masterUserRepository, SlaveUserRepository slaveUserRepository) {
        this.masterUserRepository = masterUserRepository;
        this.slaveUserRepository = slaveUserRepository;
    }

    @Override
    @Transactional(readOnly = true)
    public boolean isExistedByEmail(String email) {
        log.info("(isExistedByEmail)email: {}", email);
        return slaveUserRepository.existsByEmail(email);
    }

    @Override
    @Transactional
    public User save(String email) {
        log.info("(save)email: {}", email);
        User user = new User();
        user.setEmail(email);
        return masterUserRepository.save(user);
    }

    @Override
    @Transactional
    public void update(String userId, UpdateUserRequest request) {
        log.info("(update)request: {}", request);
        User user = slaveUserRepository.findById(userId).orElseThrow(UserNotFoundException::new);
        updateUserInfo(user, request);
        masterUserRepository.save(user);
    }

    @Override
    @Transactional(readOnly = true)
    public UserDetailResponse get(String userId) {
        User user = slaveUserRepository.findById(userId).orElseThrow(UserNotFoundException::new);
        return UserDetailResponse.builder()
                .id(user.getId())
                .name(user.getName())
                .email(user.getEmail())
                .gender(user.getGender())
                .address(user.getAddress())
                .build();
    }

    @Override
    @Transactional(readOnly = true)
    public List<UserDetailResponse> filter(FilterRequest request) {
        log.info("(filter)request: {}", request);
        return slaveUserRepository.filter(request.getQuery(), request.getSort()).stream().map(
                user ->  UserDetailResponse.builder()
                        .id(user.getId())
                        .name(user.getName())
                        .email(user.getEmail())
                        .gender(user.getGender())
                        .address(user.getAddress())
                        .build()
        ).toList();
    }

    private void updateUserInfo(User user, UpdateUserRequest request) {
        user.setGender(request.getGender() != null ? Gender.valueOf(request.getGender()) : null);
        user.setName(request.getName());
        user.setAddress(request.getAddress());
    }
}
