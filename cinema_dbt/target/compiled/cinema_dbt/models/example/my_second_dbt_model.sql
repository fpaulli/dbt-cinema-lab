-- Use the `ref` function to select from other models

select *
from "postgres"."cinema_dbt"."my_first_dbt_model"
where id = 1