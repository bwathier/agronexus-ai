# CropYieldForecast.R
# Author: Bill R. Wathier
# Description: Time series forecasting of crop yields using historical data
# Last updated: 2025-10-29

#====Personal preference, adjust per preference====
 options(prompt = "R> ")
#======

# ----------------------------------------------------------
# Define second output directory for Shiny app
output_dir <- "../CropYieldApp"
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

# ----------------------------------------------------------
# Helper function to save CSV in both dirs
save_csv_both <- function(df, filename) {
  write_csv(df, filename)
  write_csv(df, file.path(output_dir, basename(filename)))
}

# Helper function to save RData in both dirs
save_rdata_both <- function(object, filename) {
  save(list = object, file = filename)
  save(list = object, file = file.path(output_dir, basename(filename)))
}

# ----------------------------------------------------------
# STEP 0: Option to Install Required Packages, remove/add '#' if needed
# ----------------------------------------------------------
packages <- c("WDI", "prophet", "dplyr", "ggplot2", "readr", "lubridate", 
              "nasapower", "tidyr", "Metrics")
 install_if_missing <- function(p) {
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
}
 lapply(packages, install_if_missing)
# =======Hashtags added above, remove if needing to add packages

# ----------------------------------------------------------
# STEP 1: Load Libraries
# ----------------------------------------------------------
library(WDI)
library(prophet)
library(dplyr)
library(ggplot2)
library(readr)
library(lubridate)
library(nasapower)
library(tidyr)
library(Metrics)

# ----------------------------------------------------------
# STEP 2: Fetch Maize Yield Data from World Bank (WDI)
# ----------------------------------------------------------
yield_raw <- WDI(country = "KE", indicator = "AG.YLD.CREL.KG", start = 1990, end = as.integer(format(Sys.Date(), "%Y")))

yield_data <- yield_raw %>%
  rename(y = AG.YLD.CREL.KG, year = year) %>%
  mutate(
    ds = as.Date(paste0(year, "-06-01")),
    y = y / 1000  # kg/ha → tons/ha
  ) %>%
  select(ds, y, year)

# ----------------------------------------------------------
# STEP 3: Fetch Rainfall + Temperature from NASA POWER
# ----------------------------------------------------------
lat <- -1.2921   # Nairobi chosen as a case study example
lon <- 36.8219
start_date <- min(yield_data$ds)
end_date <- max(yield_data$ds)

climate_daily <- get_power(
  community = "AG",
  lonlat = c(lon, lat),
  pars = c("PRECTOTCORR", "T2M"),  # rainfall + temperature
  dates = c(as.character(start_date), as.character(end_date))
) %>%
  mutate(
    date = as.Date(DOY - 1, origin = paste0(YEAR, "-01-01")),
    rainfall_mm = PRECTOTCORR,
    temperature_C = T2M
  ) %>%
  select(date, rainfall_mm, temperature_C)

# Save daily climate data as CSV in both dirs
csv_filename <- paste0("nasa_power_climate_", format(start_date, "%Y%m%d"), "_to_", format(end_date, "%Y%m%d"), ".csv")
save_csv_both(climate_daily, csv_filename)
message("Saved NASA POWER climate data to: ", csv_filename, " and ", file.path(output_dir, basename(csv_filename)))

# ----------------------------------------------------------
# STEP 4: Aggregate Rainfall + Temperature Annually
# ----------------------------------------------------------
climate_annual <- climate_daily %>%
  mutate(year = format(date, "%Y")) %>%
  group_by(year) %>%
  summarise(
    total_rainfall = sum(rainfall_mm, na.rm = TRUE),
    avg_temp = mean(temperature_C, na.rm = TRUE)
  ) %>%
  ungroup() %>%
  mutate(year = as.integer(year))

# ----------------------------------------------------------
# STEP 5: Merge Yield + Climate Data + Lag Rainfall
# ----------------------------------------------------------
merged_data <- left_join(yield_data, climate_annual, by = "year") %>%
  rename(rainfall = total_rainfall, temperature = avg_temp) %>%
  arrange(ds) %>%
  mutate(
    rainfall_lag1 = lag(rainfall, 1)
  ) %>%
  select(ds, y, year, rainfall, rainfall_lag1, temperature) %>%
  drop_na()

# ----------------------------------------------------------
# STEP 5b: Load and Process Maize Price Data (Wide Format)
# ----------------------------------------------------------
csv_path <- "data/KEN_RTFP_mkt_2007_2025.csv"
if (!file.exists(csv_path)) {
  stop("Missing required file: KEN_RTFP_mkt_2007_2025.csv in /data/. 
       Please check the path.")
}

# Load Price data
price_data <- read_csv(csv_path)  

price_annual <- price_data %>%
  filter(!is.na(maize)) %>%
  group_by(year) %>%
  summarise(average_price = mean(maize, na.rm = TRUE)) %>%
  ungroup()

# Merge into dataset
merged_data <- merged_data %>%
  left_join(price_annual, by = "year") %>%
  drop_na(average_price)

# Save merged data for review in both dirs
save_csv_both(merged_data %>% mutate(Year = format(ds, "%Y")), "historical_yield_with_climate_and_price.csv")

# ----------------------------------------------------------
# STEP 6: Train Prophet Model with 4 Regressors
# ----------------------------------------------------------
m <- prophet()  # Using prophet for flexibility and handling seasonality
m <- add_regressor(m, 'rainfall')
m <- add_regressor(m, 'rainfall_lag1')
m <- add_regressor(m, 'temperature')
m <- add_regressor(m, 'average_price')
m <- fit.prophet(m, merged_data)

# ----------------------------------------------------------
# STEP 7: Forecast Next 5 Years
# ----------------------------------------------------------
future <- make_future_dataframe(m, periods = 5, freq = "year")

# Log forecast horizon
message("Forecasting maize yield for next 5 years: ", 
        format(max(merged_data$ds) + lubridate::years(1)), 
        " to ", 
        format(max(merged_data$ds) + lubridate::years(5)))

future$rainfall <- c(merged_data$rainfall, rep(mean(merged_data$rainfall, na.rm = TRUE), 5))
future$rainfall_lag1 <- c(merged_data$rainfall_lag1, rep(mean(merged_data$rainfall_lag1, na.rm = TRUE), 5))
future$temperature <- c(merged_data$temperature, rep(mean(merged_data$temperature, na.rm = TRUE), 5))
future$average_price <- c(merged_data$average_price, rep(mean(merged_data$average_price, na.rm = TRUE), 5))

forecast <- predict(m, future)

# ----------------------------------------------------------
# STEP 8: Combine Actual + Forecast + Export
# ----------------------------------------------------------
combined_data <- forecast %>%
  mutate(Year = format(ds, "%Y"),
         Type = ifelse(ds <= max(merged_data$ds), "Actual", "Forecast"),
         ds = as.Date(ds)) %>%
  select(Year, ds, yhat, yhat_lower, yhat_upper, Type)

combined_data <- left_join(combined_data,
                           merged_data %>%
                             rename(yield_actual = y) %>%
                             mutate(Year = format(ds, "%Y")) %>%
                             select(Year, ds, yield_actual),
                           by = c("Year", "ds"))

save_csv_both(combined_data, "maize_yield_forecast_with_price.csv")

# Log number of rows saved
message("Saved ", nrow(combined_data), 
        " rows to maize_yield_forecast_with_price.csv")

# ----------------------------------------------------------
# STEP 9: Quantitative Impact Assessment (Metrics)
# ----------------------------------------------------------
actuals <- combined_data %>% filter(Type == "Actual") %>% pull(yield_actual)
predictions <- combined_data %>% filter(Type == "Actual") %>% pull(yhat)

mae_val <- mae(actuals, predictions)
mape_val <- mape(actuals, predictions) * 100
rmse_val <- rmse(actuals, predictions)

cat("\nModel Performance Metrics:\n")
cat(sprintf("MAE: %.3f\n", mae_val))
cat(sprintf("MAPE: %.2f%%\n", mape_val))
cat(sprintf("RMSE: %.3f\n", rmse_val))

# Save metrics to CSV for dashboard or review
metrics <- data.frame(MAE = mae_val, MAPE = mape_val, RMSE = rmse_val)
save_csv_both(metrics, "model_performance_metrics.csv")

residuals_df <- combined_data %>%
  filter(Type == "Actual") %>%
  mutate(residual = yield_actual - yhat)

# ----------------------------------------------------------
# STEP 10: Save model and forecast for Shiny use in both dirs
# ----------------------------------------------------------
save_rdata_both("m", "prophet_model.RData")
save_rdata_both("forecast", "prophet_forecast.RData")
save_rdata_both("combined_data", "combined_data.RData")
save_rdata_both("residuals_df", "residuals_df.RData")

# END OF CropYieldForecast.R
