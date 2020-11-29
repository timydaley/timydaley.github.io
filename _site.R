## packages I want loaded for all pages of my site
suppressPackageStartupMessages({
  library(reticulate)
})


## knitr options I want set as default for all ('global') code chunks
knitr::opts_chunk$set(message = FALSE, warning = FALSE)