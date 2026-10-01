{#- Tag every query dbt runs with the model name, so Snowflake Query History shows which model ran it.
    A query_tag set in a model's config still wins. Overrides dbt-snowflake's built-in versions,
    which only tag (and reset) when query_tag is configured explicitly. -#}
{% macro snowflake__set_query_tag() -%}
    {% set new_query_tag = config.get('query_tag') or ('dbt_hol.' ~ model.name) %}
    {% set original_query_tag = get_current_query_tag() %}
    {{ log("Setting query_tag to '" ~ new_query_tag ~ "'. Will reset to '" ~ original_query_tag ~ "' after materialization.") }}
    {% do run_query("alter session set query_tag = '{}'".format(new_query_tag)) %}
    {{ return(original_query_tag) }}
{%- endmacro %}

{% macro snowflake__unset_query_tag(original_query_tag) -%}
    {% if original_query_tag %}
        {{ log("Resetting query_tag to '" ~ original_query_tag ~ "'.") }}
        {% do run_query("alter session set query_tag = '{}'".format(original_query_tag)) %}
    {% else %}
        {{ log("No original query_tag, unsetting parameter.") }}
        {% do run_query("alter session unset query_tag") %}
    {% endif %}
{%- endmacro %}
