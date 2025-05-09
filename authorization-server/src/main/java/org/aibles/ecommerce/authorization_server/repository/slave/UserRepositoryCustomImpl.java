package org.aibles.ecommerce.authorization_server.repository.slave;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.criteria.*;
import org.aibles.ecommerce.authorization_server.dto.QueryModel;
import org.aibles.ecommerce.authorization_server.dto.SortModel;
import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.entity.User_;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Repository;

import java.util.ArrayList;
import java.util.List;

@Repository
public class UserRepositoryCustomImpl implements UserRepositoryCustom {

    private final EntityManager entityManager;

    public UserRepositoryCustomImpl(@Qualifier("slaveEntityManager") EntityManagerFactory entityManagerFactory) {
        this.entityManager = entityManagerFactory.createEntityManager();
    }

    @Override
    public List<User> filter(List<QueryModel> query, List<SortModel> sort) {
        CriteriaBuilder cb = entityManager.getCriteriaBuilder();
        CriteriaQuery<User> cq = cb.createQuery(User.class);
        Root<User> root = cq.from(User.class);

        List<Predicate> predicates = new ArrayList<>();
        if (query != null && !query.isEmpty()) {
            for(QueryModel qm : query) {
                createPredicates(qm, predicates, cb, root);
            }
        }

        cq.where(predicates.toArray(new Predicate[0]));

        List<Order> orders = new ArrayList<>();
        if (sort != null && !sort.isEmpty()) {
            for(SortModel sm : sort) {
                createOrders(sm, orders, cb, root);
            }
        }

        cq.orderBy(orders);

        return entityManager.createQuery(cq).getResultList();
    }

    private void createOrders(SortModel sm, List<Order> orders, CriteriaBuilder cb, Root<User> root) {
        if (sm.getField().equals(User_.ID)) {
            orders.add(createOrder(cb, root, User_.ID, sm.getDirection()));
        }
        if (sm.getField().equals(User_.NAME)) {
            orders.add(createOrder(cb, root, User_.NAME, sm.getDirection()));
        }
        if (sm.getField().equals(User_.EMAIL)) {
            orders.add(createOrder(cb, root, User_.EMAIL, sm.getDirection()));
        }
        if (sm.getField().equals(User_.ADDRESS)) {
            orders.add(createOrder(cb, root, User_.ADDRESS, sm.getDirection()));
        }
        if (sm.getField().equals(User_.GENDER)) {
            orders.add(createOrder(cb, root, User_.GENDER, sm.getDirection()));
        }
    }

    private void createPredicates(QueryModel qm, List<Predicate> predicates, CriteriaBuilder cb, Root<User> root) {
        if (qm.getField().equals(User_.ID)) {
            predicates.add(createPredicate(cb, root, User_.ID, qm.getOperation(), qm.getValue()));
        }
        if (qm.getField().equals(User_.NAME)) {
            predicates.add(createPredicate(cb, root, User_.NAME, qm.getOperation(), qm.getValue()));
        }
        if (qm.getField().equals(User_.EMAIL)) {
            predicates.add(createPredicate(cb, root, User_.EMAIL, qm.getOperation(), qm.getValue()));
        }
        if (qm.getField().equals(User_.ADDRESS)) {
            predicates.add(createPredicate(cb, root, User_.ADDRESS, qm.getOperation(), qm.getValue()));
        }
        if (qm.getField().equals(User_.GENDER)) {
            predicates.add(createPredicate(cb, root, User_.GENDER, qm.getOperation(), qm.getValue()));
        }
    }

    private Predicate createPredicate(CriteriaBuilder cb, Root<User> root, String field, String operation, String value) {

        switch (operation) {
            case "eq":
                return cb.equal(root.get(field), value);
            case "ne":
                return cb.notEqual(root.get(field), value);
            case "gt":
                return cb.greaterThan(root.get(field), value);
            case "lt":
                return cb.lessThan(root.get(field), value);
            case "ge":
                return cb.greaterThanOrEqualTo(root.get(field), value);
            case "le":
                return cb.lessThanOrEqualTo(root.get(field), value);
            case "like":
                return cb.like(root.get(field), value);
        }
        return null;
    }

    private Order createOrder(CriteriaBuilder cb, Root<User> root, String field, String direction) {
        switch (direction) {
            case "asc":
                return cb.asc(root.get(field));
            case "desc":
                return cb.desc(root.get(field));
        }
        return null;
    }
}
