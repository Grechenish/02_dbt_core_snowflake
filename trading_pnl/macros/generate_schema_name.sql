{#- Where each model is built.
    prod:      the folder's schema as-is, e.g. ANALYTICS.MARTS
    dev / ci:  prefixed with the target schema, e.g. ANALYTICS_DEV.DEV_VIKTOR_MARTS or ANALYTICS_DEV.CI_PR_12_MARTS
    so two developers, or a developer and a pull request, never build into the same schema.
    This is dbt's built-in generate_schema_name_for_env, which keys on the target being named `prod`. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ generate_schema_name_for_env(custom_schema_name, node) }}
{%- endmacro %}
