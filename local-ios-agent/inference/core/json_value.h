#ifndef LOCAL_AGENT_JSON_VALUE_H
#define LOCAL_AGENT_JSON_VALUE_H

#include <map>
#include <string>
#include <vector>

namespace local_agent::json {

class Value {
public:
    enum class Type {
        null_value,
        bool_value,
        number_value,
        string_value,
        array_value,
        object_value
    };

    Value();
    explicit Value(bool value);
    explicit Value(double value);
    explicit Value(std::string value);
    explicit Value(std::vector<Value> value);
    explicit Value(std::map<std::string, Value> value);

    Type type() const;
    bool is_object() const;
    bool is_array() const;
    const std::string &as_string() const;
    double as_number() const;
    bool as_bool() const;
    const std::vector<Value> &as_array() const;
    const std::map<std::string, Value> &as_object() const;
    const Value *get(const std::string &key) const;

private:
    Type type_ = Type::null_value;
    bool bool_value_ = false;
    double number_value_ = 0.0;
    std::string string_value_;
    std::vector<Value> array_value_;
    std::map<std::string, Value> object_value_;
};

Value parse(const char *json);
std::string require_string(const Value &object, const std::string &key);
std::string optional_string(const Value &object, const std::string &key, const std::string &fallback);
int optional_int(const Value &object, const std::string &key, int fallback);
float optional_float(const Value &object, const std::string &key, float fallback);

} // namespace local_agent::json

#endif
