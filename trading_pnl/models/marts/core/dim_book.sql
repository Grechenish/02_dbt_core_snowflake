-- Trading books, published from the `books` seed so reporters read them from the marts schema
-- alongside the facts.
select book, desk_name, base_currency
from {{ ref('books') }}
