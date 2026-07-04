#include "json_value.h"

#include <cerrno>
#include <cstdlib>
#include <stdexcept>

namespace local_agent::json {
namespace {

class Parser {
public:
    explicit Parser(const char *json)
        : json_(json == nullptr ? "" : json) {
        if (json == nullptr) {
            throw std::invalid_argument("json input is null");
        }
    }

    Value parse_root() {
        skip_whitespace();
        Value value = parse_value();
        skip_whitespace();
        if (json_[pos_] != '\0') {
            throw std::invalid_argument("trailing characters after json value");
        }
        return value;
    }

private:
    Value parse_value() {
        skip_whitespace();
        const char c = json_[pos_];
        if (c == '{') {
            return Value(parse_object());
        }
        if (c == '[') {
            return Value(parse_array());
        }
        if (c == '"') {
            return Value(parse_string());
        }
        if (c == 't') {
            consume_literal("true");
            return Value(true);
        }
        if (c == 'f') {
            consume_literal("false");
            return Value(false);
        }
        if (c == 'n') {
            consume_literal("null");
            return Value();
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            return Value(parse_number());
        }
        throw std::invalid_argument("unexpected json value");
    }

    std::map<std::string, Value> parse_object() {
        expect('{');
        std::map<std::string, Value> object;
        skip_whitespace();
        if (peek('}')) {
            ++pos_;
            return object;
        }
        while (true) {
            skip_whitespace();
            if (!peek('"')) {
                throw std::invalid_argument("object key must be a string");
            }
            std::string key = parse_string();
            skip_whitespace();
            expect(':');
            object.emplace(std::move(key), parse_value());
            skip_whitespace();
            if (peek('}')) {
                ++pos_;
                return object;
            }
            expect(',');
        }
    }

    std::vector<Value> parse_array() {
        expect('[');
        std::vector<Value> array;
        skip_whitespace();
        if (peek(']')) {
            ++pos_;
            return array;
        }
        while (true) {
            array.push_back(parse_value());
            skip_whitespace();
            if (peek(']')) {
                ++pos_;
                return array;
            }
            expect(',');
        }
    }

    std::string parse_string() {
        expect('"');
        std::string result;
        while (true) {
            const char c = json_[pos_++];
            if (c == '\0') {
                throw std::invalid_argument("unterminated json string");
            }
            if (c == '"') {
                return result;
            }
            if (c == '\\') {
                const char escaped = json_[pos_++];
                switch (escaped) {
                case '"':
                    result.push_back('"');
                    break;
                case '\\':
                    result.push_back('\\');
                    break;
                case '/':
                    result.push_back('/');
                    break;
                case 'n':
                    result.push_back('\n');
                    break;
                case 'r':
                    result.push_back('\r');
                    break;
                case 't':
                    result.push_back('\t');
                    break;
                case 'b':
                    result.push_back('\b');
                    break;
                case 'f':
                    result.push_back('\f');
                    break;
                default:
                    throw std::invalid_argument("unsupported json string escape");
                }
            } else {
                result.push_back(c);
            }
        }
    }

    double parse_number() {
        char *end = nullptr;
        errno = 0;
        const double number = std::strtod(json_ + pos_, &end);
        if (end == json_ + pos_ || errno == ERANGE) {
            throw std::invalid_argument("invalid json number");
        }
        pos_ = static_cast<size_t>(end - json_);
        return number;
    }

    void consume_literal(const char *literal) {
        for (size_t i = 0; literal[i] != '\0'; ++i) {
            if (json_[pos_ + i] != literal[i]) {
                throw std::invalid_argument("invalid json literal");
            }
        }
        pos_ += std::string(literal).size();
    }

    void expect(char expected) {
        skip_whitespace();
        if (json_[pos_] != expected) {
            throw std::invalid_argument("unexpected json character");
        }
        ++pos_;
    }

    bool peek(char expected) const {
        return json_[pos_] == expected;
    }

    void skip_whitespace() {
        while (json_[pos_] == ' ' || json_[pos_] == '\n' || json_[pos_] == '\r' || json_[pos_] == '\t') {
            ++pos_;
        }
    }

    const char *json_;
    size_t pos_ = 0;
};

const Value &require_object(const Value &value) {
    if (!value.is_object()) {
        throw std::invalid_argument("json value must be an object");
    }
    return value;
}

} // namespace

Value::Value() = default;

Value::Value(bool value)
    : type_(Type::bool_value),
      bool_value_(value) {}

Value::Value(double value)
    : type_(Type::number_value),
      number_value_(value) {}

Value::Value(std::string value)
    : type_(Type::string_value),
      string_value_(std::move(value)) {}

Value::Value(std::vector<Value> value)
    : type_(Type::array_value),
      array_value_(std::move(value)) {}

Value::Value(std::map<std::string, Value> value)
    : type_(Type::object_value),
      object_value_(std::move(value)) {}

Value::Type Value::type() const {
    return type_;
}

bool Value::is_object() const {
    return type_ == Type::object_value;
}

bool Value::is_array() const {
    return type_ == Type::array_value;
}

const std::string &Value::as_string() const {
    if (type_ != Type::string_value) {
        throw std::invalid_argument("json value is not a string");
    }
    return string_value_;
}

double Value::as_number() const {
    if (type_ != Type::number_value) {
        throw std::invalid_argument("json value is not a number");
    }
    return number_value_;
}

bool Value::as_bool() const {
    if (type_ != Type::bool_value) {
        throw std::invalid_argument("json value is not a bool");
    }
    return bool_value_;
}

const std::vector<Value> &Value::as_array() const {
    if (type_ != Type::array_value) {
        throw std::invalid_argument("json value is not an array");
    }
    return array_value_;
}

const std::map<std::string, Value> &Value::as_object() const {
    if (type_ != Type::object_value) {
        throw std::invalid_argument("json value is not an object");
    }
    return object_value_;
}

const Value *Value::get(const std::string &key) const {
    if (!is_object()) {
        return nullptr;
    }
    const auto it = object_value_.find(key);
    if (it == object_value_.end()) {
        return nullptr;
    }
    return &it->second;
}

Value parse(const char *json) {
    return Parser(json).parse_root();
}

std::string require_string(const Value &object, const std::string &key) {
    const Value *value = require_object(object).get(key);
    if (value == nullptr) {
        throw std::invalid_argument("missing required string key: " + key);
    }
    return value->as_string();
}

std::string optional_string(const Value &object, const std::string &key, const std::string &fallback) {
    const Value *value = require_object(object).get(key);
    if (value == nullptr) {
        return fallback;
    }
    return value->as_string();
}

int optional_int(const Value &object, const std::string &key, int fallback) {
    const Value *value = require_object(object).get(key);
    if (value == nullptr) {
        return fallback;
    }
    return static_cast<int>(value->as_number());
}

float optional_float(const Value &object, const std::string &key, float fallback) {
    const Value *value = require_object(object).get(key);
    if (value == nullptr) {
        return fallback;
    }
    return static_cast<float>(value->as_number());
}

} // namespace local_agent::json
