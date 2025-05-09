package org.aibles.ecommerce.orchestrator_service.util;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.apache.avro.Schema;
import org.apache.avro.io.DatumReader;
import org.apache.avro.io.Decoder;
import org.apache.avro.io.DecoderFactory;
import org.apache.avro.specific.SpecificDatumReader;
import org.apache.avro.specific.SpecificRecordBase;

import java.io.IOException;

@Slf4j
public class AvroConverter {

    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    private AvroConverter() {}

    public static <T extends SpecificRecordBase> T convert(String input, Class<T> clazz, Schema schema) throws IOException {
        log.info("(convert)Converting {} to {}", input, schema);
        JsonNode jsonNode = OBJECT_MAPPER.readTree(input);
        byte[] jsonBytes = OBJECT_MAPPER.writeValueAsBytes(jsonNode);

        DatumReader<T> datumReader = new SpecificDatumReader<>(clazz);
        Decoder decoder;
        try {
            decoder = DecoderFactory.get().jsonDecoder(
                    schema, new String(jsonBytes));
            return datumReader.read(null, decoder);
        } catch (IOException e) {
            log.error("(convert)Deserialization error: {}", e.getMessage());
        }
        return null;
    }
}
