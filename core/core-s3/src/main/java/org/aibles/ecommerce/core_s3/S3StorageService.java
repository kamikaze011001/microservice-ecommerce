package org.aibles.ecommerce.core_s3;

public interface S3StorageService {

    /**
     * Mint a presigned PUT URL the client can use to upload directly to S3.
     * The signed URL embeds Content-Type as a condition; uploads with a different
     * Content-Type are rejected by S3.
     */
    PresignedUpload presignUpload(String objectKey, String contentType);

    /** HEAD the object; true if it exists. */
    boolean objectExists(String objectKey);

    /** Convert an object key into the public URL stored in the database. */
    String publicUrl(String objectKey);
}
