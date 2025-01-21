# 为每年的野火分配土地覆盖变量
# 野火数据是基于点的
# 通过使用燃烧面积数据近似估计火灾范围，计算每个火灾周围的土地覆盖情况

# 安装并加载必要的R包
if (!require(terra)) install.packages('terra')
if (!require(sf)) install.packages('sf')
if (!require(tidyverse)) install.packages('tidyverse')
if (!require(readxl)) install.packages('readxl')
library(terra)
library(sf)
library(tidyverse)
library(readxl)

# 清空当前环境变量
rm(list=ls())

# 设置工作路径
path <- "/Users/dariaageikina/Downloads/wildfires/data"
setwd(path)

# 加载野火事件数据
incidents <- st_read("build_wildfire_reports/output/incidents_spatial.gpkg")
incidents <- filter(incidents, POO_state != "AK")  # 过滤掉阿拉斯加的野火数据
incidents <- subset(incidents, select = c(incident_id, start_year, final_acres))  # 只保留需要的列

# 近似估计火灾范围（将燃烧面积转换为圆形缓冲区）
incidents$final_sq_m <- incidents$final_acres * 4046.8564224  # 将英亩转换为平方米
incidents$radius <- sqrt(incidents$final_sq_m / pi)  # 计算圆形缓冲区的半径
incidents <- st_buffer(incidents, incidents$radius)  # 创建缓冲区

# 初始化土地覆盖变量（树冠覆盖、灌木覆盖、草本覆盖）
incidents$tree_cover_p <- 0
incidents$shrub_cover_p <- 0
incidents$herb_cover_p <- 0

# 设置土地覆盖数据的路径
path <- "build_land_cover"
input_path <- paste0(path, "/input/raw/cms_conus")
output_path <- paste0(path, "/output")

# 从NASA的EARTH Data下载数据，使用提供的wget命令列表
wget_commands <- read_excel(paste0(input_path, "/wget_commands3.xlsx"))
wget_commands$command <- paste0('wget -r -np -nH --reject "index.html*" -e robots=off ', wget_commands$link)

# 遍历每年的土地覆盖数据
for (i in 1:nrow(wget_commands)) {
  
  year <- wget_commands$year[i]  # 获取当前年份
  type <- wget_commands$type[i]  # 获取土地覆盖类型（树冠、灌木、草本）
  incidents_year <- filter(incidents, start_year == year)  # 过滤出当前年份的野火数据
  
  setwd(input_path)
  system(wget_commands$command[i])  # 执行wget命令下载数据
  
  # 加载下载的土地覆盖栅格数据
  files <- list.files(input_path, recursive = TRUE, pattern = ".tif", full.names = TRUE)
  land_rasts <- lapply(files, rast, lyrs = 1)  # 读取每个文件的第一个图层（均值估计）
  
  combined_raster <- do.call(merge, land_rasts)  # 合并所有栅格数据
  
  # 提取每个野火缓冲区内的土地覆盖均值
  land_values <- terra::extract(combined_raster, incidents_year, mean, na.rm = TRUE)
  land_values[is.na(land_values)] <- 0  # 将空值替换为0
  
  # 根据土地覆盖类型分配值
  if (type == "TC") {
    incidents_year$tree_cover_p <- rowMeans(land_values[2])  # 树冠覆盖
  } else if (type == "SC") {
    incidents_year$shrub_cover_p <- rowMeans(land_values[2])  # 灌木覆盖
  } else {
    incidents_year$herb_cover_p <- rowMeans(land_values[2])  # 草本覆盖
  }

  # 移除几何列以便保存为CSV
  incidents_year <- st_set_geometry(incidents_year, NULL)

  # 根据土地覆盖类型保存结果
  if (type == "TC") {
    incidents_year <- subset(incidents_year, select = c(incident_id, tree_cover_p))
    write.csv(incidents_year, paste0(path, "/input/built/conus/tree_cover/", year, ".csv"))
  } else if (type == "SC") {
    incidents_year <- subset(incidents_year, select = c(incident_id, shrub_cover_p))
    write.csv(incidents_year, paste0(path, "/input/built/conus/shrub_cover/", year, ".csv"))
  } else {
    incidents_year <- subset(incidents_year, select = c(incident_id, herb_cover_p))
    write.csv(incidents_year, paste0(path, "/input/built/conus/herb_cover/", year, ".csv"))
  }
  
  # 删除下载的文件以释放空间
  unlink(files)
}
