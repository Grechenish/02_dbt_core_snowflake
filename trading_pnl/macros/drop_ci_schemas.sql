{#- Drops every schema a pull request's CI runs built, when the pull request closes:
      dbt run-operation drop_ci_schemas --target ci --args '{schema_prefix: CI_PR_12}'
    Refuses to run outside the ci target or for a prefix that isn't a CI one, so it can never
    drop production or a developer's schemas. -#}
{% macro drop_ci_schemas(schema_prefix) %}
    {% set prefix = schema_prefix | upper %}
    {% if target.name != 'ci' or not prefix.startswith('CI_PR_') %}
        {{ exceptions.raise_compiler_error("drop_ci_schemas only drops CI_PR_* schemas on the ci target, got " ~ prefix ~ " on " ~ target.name) }}
    {% endif %}

    {% set schemas = run_query("show terse schemas in database " ~ target.database).columns['name'].values() %}
    {% for schema in schemas if schema == prefix or schema.startswith(prefix ~ '_') %}
        {% do log("Dropping " ~ target.database ~ "." ~ schema, info=true) %}
        {% do run_query("drop schema if exists " ~ target.database ~ "." ~ schema ~ " cascade") %}
    {% else %}
        {% do log("No schemas start with " ~ prefix, info=true) %}
    {% endfor %}
{% endmacro %}
