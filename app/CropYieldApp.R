library(shiny)
library(ggplot2)
library(dplyr)
library(Metrics)

# Load preprocessed data
load("combined_data.RData")   # combined_data with ds, yhat, yield_actual, etc.
load("residuals_df.RData")    # residuals_df with ds, residual

ui <- fluidPage(
  # Ensure mobile responsiveness
  tags$head(
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1")
  ),
  
  titlePanel("Crop Yield Forecast Dashboard"),
  
  # Controls Panel
  fluidRow(
    column(
      width = 12,
      wellPanel(
        fluidRow(
          column(
            width = 12, class = "mb-3",
            sliderInput("yearRange", "Select Year Range:",
                        min = min(as.integer(format(combined_data$ds, "%Y"))),
                        max = max(as.integer(format(combined_data$ds, "%Y"))),
                        value = c(min(as.integer(format(combined_data$ds, "%Y"))),
                                  max(as.integer(format(combined_data$ds, "%Y")))),
                        step = 1, sep = "")
          ),
          column(
            width = 6,
            checkboxInput("showCI", "Show Confidence Interval", value = TRUE)
          ),
          column(
            width = 6,
            checkboxInput("showActual", "Show Actual Data", value = TRUE)
          )
        )
      )
    )
  ),
  
  # Forecast Plot
  fluidRow(
    column(12, plotOutput("forecastPlot", height = "400px"))
  ),
  
  # Model Metrics
  fluidRow(
    column(12, verbatimTextOutput("modelMetrics"))
  ),
  
  # Residuals Plot
  fluidRow(
    column(12, plotOutput("residualsPlot", height = "400px"))
  )
)

server <- function(input, output) {
  
  filtered_data <- reactive({
    combined_data %>%
      filter(as.integer(format(ds, "%Y")) >= input$yearRange[1],
             as.integer(format(ds, "%Y")) <= input$yearRange[2])
  })
  
  output$forecastPlot <- renderPlot({
    df <- filtered_data()
    gg <- ggplot(df, aes(x = ds)) +
      geom_line(aes(y = yhat, color = "Forecast"), size = 1)
    
    if (input$showCI) {
      gg <- gg + geom_ribbon(aes(ymin = yhat_lower, ymax = yhat_upper), fill = "lightblue", alpha = 0.3)
    }
    if (input$showActual) {
      gg <- gg + geom_point(aes(y = yield_actual, color = "Actual"), size = 2)
    }
    
    gg + scale_color_manual(values = c("Forecast" = "blue", "Actual" = "black")) +
      labs(title = "Maize Yield: Actual vs Forecast",
           x = "Date", y = "Yield (tons/ha)") +
      theme_minimal()
  })
  
  output$modelMetrics <- renderPrint({
    df <- filtered_data() %>% filter(Type == "Actual")
    actuals <- df$yield_actual
    preds <- df$yhat
    
    mae_val <- mae(actuals, preds)
    mape_val <- mape(actuals, preds) * 100
    rmse_val <- rmse(actuals, preds)
    
    cat("Model Performance Metrics:\n")
    cat(sprintf("MAE: %.3f\n", mae_val))
    cat(sprintf("MAPE: %.2f%%\n", mape_val))
    cat(sprintf("RMSE: %.3f\n", rmse_val))
  })
  
  output$residualsPlot <- renderPlot({
    df <- residuals_df %>%
      filter(as.integer(format(ds, "%Y")) >= input$yearRange[1],
             as.integer(format(ds, "%Y")) <= input$yearRange[2])
    
    ggplot(df, aes(x = ds, y = residual)) +
      geom_hline(yintercept = 0, linetype = "dashed", color = "red") +
      geom_line(color = "purple", size = 1) +
      geom_point(color = "purple", size = 2) +
      labs(title = "Residuals Over Time", x = "Date", y = "Residual (Actual - Predicted)") +
      theme_minimal()
  })
  
}

# Launch the app
shinyApp(ui, server)
