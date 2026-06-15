options(repos = c(CRAN = "https://cloud.r-project.org"))
pkgs <- c("arrow", "dplyr", "tidyr", "plm", "lmtest", "sandwich",
          "broom", "ggplot2", "readr", "scales", "tibble")
missing <- pkgs[!pkgs %in% installed.packages()[,"Package"]]
if (length(missing)) install.packages(missing)
