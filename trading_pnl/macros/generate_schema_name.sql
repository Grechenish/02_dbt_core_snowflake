{#- Use the custom schema name as-is (staging / intermediate / marts).
    Dev and prod are already separated by database, so no target-schema prefix is needed. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
