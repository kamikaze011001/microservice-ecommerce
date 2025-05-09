package org.aibles.ecommerce.authorization_server.annotation;

import jakarta.validation.Constraint;
import jakarta.validation.ConstraintValidator;
import jakarta.validation.ConstraintValidatorContext;
import jakarta.validation.Payload;

import java.lang.annotation.*;
import java.util.regex.Pattern;

@Documented
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.FIELD)
@Constraint(validatedBy = ValidPassword.PasswordValidator.class)
public @interface ValidPassword {

    String message() default """
            Password must have at least 6 characters, contains uppercase,
            lowercase, number and special characters: !@#$%^&*()
            """;

    Class<?>[] groups() default {};

    Class<? extends Payload>[] payload() default {};

    class PasswordValidator implements ConstraintValidator<ValidPassword, String> {

        @Override
        public boolean isValid(String password, ConstraintValidatorContext constraintValidatorContext) {
            Pattern pattern = Pattern.compile("^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d)(?=.*[!@#$%^&*()])[A-Za-z\\d!@#$%^&*()]{6,}$");
            return pattern.matcher(password).matches();
        }
    }
}
