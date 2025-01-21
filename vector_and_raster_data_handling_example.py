# 将森林地块数据与CARB项目数据（美国森林项目，来自合规抵消计划）、野火风险潜力、保护地役权和树冠覆盖数据合并
import geopandas as gpd
import rasterio
from rasterstats import zonal_stats
import os

# 设置数据路径
path = "/Users/dariaageikina/Downloads"

# 加载森林地块数据
parcels = gpd.read_file(os.path.join(path, "forest_parcels1km.gpkg"))
parcels = parcels.to_crs('EPSG:5070')  # 使用公制坐标系（EPSG:5070）以确保计算精度
parcels['parcel_id'] = parcels.index + 1  # 为每个地块生成唯一ID
parcels['parcel_area'] = parcels.geometry.area  # 计算每个地块的面积

# 加载CARB项目数据（多边形或多面体）
projects = gpd.read_file(os.path.join(path, "all_projects.gpkg"))
projects = projects[projects.geometry.type.isin(['Polygon', 'MultiPolygon'])]  # 仅保留多边形和多面体数据
projects = projects.to_crs(parcels.crs)  # 将坐标系转换为与地块数据一致

# 计算每个地块中CARB项目的面积占比
intersected = gpd.overlay(parcels, projects, how='intersection')  # 计算地块与项目的交集
intersected['intersect_area'] = intersected.geometry.area  # 计算交集的面积

# 按地块ID和项目ID汇总交集面积
intersected_summed = intersected.groupby(['parcel_id', 'project'])['intersect_area'].sum().reset_index()
intersected_summed = intersected_summed.groupby('parcel_id').agg({
    'project': lambda x: ', '.join(x.astype(str)),  # 将项目ID拼接为字符串
    'intersect_area': 'sum'  # 计算每个地块的总交集面积
}).reset_index()

# 将汇总结果合并到地块数据中
alldata = parcels.merge(intersected_summed, on='parcel_id', how='left')
alldata['intersect_area'] = alldata['intersect_area'].fillna(0)  # 将空值填充为0
alldata['project_share'] = alldata['intersect_area'] / alldata['parcel_area']  # 计算项目占地比例
alldata.drop(columns=['intersect_area'], inplace=True)  # 删除临时列

# 计算每个地块的平均野火风险潜力
# 首先检查野火风险潜力数据的元数据
whp_path = path + '/2014/RDS-2015-0047/Data/whp_2014_continuous/whp2014_cnt'
with rasterio.open(whp_path) as src:
    print(src.meta)

# 使用zonal_stats计算每个地块的平均野火风险潜力
stats = zonal_stats(alldata, whp_path, stats='mean', nodata=-2147483647)
alldata['whp_2014'] = [stat['mean'] for stat in stats]  # 将结果添加到数据中
alldata = alldata.dropna(subset=['whp_2014'])  # 删除野火风险潜力为空的地块
alldata.reset_index(drop=True, inplace=True)  # 重置索引

# 加载保护地役权数据
CEs = gpd.read_file(os.path.join(path, "NCED_08282020_shp"))
CEs = CEs.to_crs(parcels.crs)  # 转换坐标系
CEs = CEs[CEs['owntype'] != 'FED']  # 过滤掉联邦政府所有的地役权
CEs = CEs[['unique_id', 'geometry']]  # 仅保留唯一ID和几何列
CEs.rename(columns={'unique_id': 'ce_id'}, inplace=True)  # 重命名列

# 检查地块是否与保护地役权相交
intersected2 = gpd.sjoin(parcels, CEs, how='left', predicate='intersects')  # 空间连接
intersected2 = intersected2.groupby('parcel_id').agg({
    'ce_id': lambda x: ', '.join(x.astype(str))  # 将相交的地役权ID拼接为字符串
}).reset_index()

# 标记是否有保护地役权
intersected2['ce'] = 0
intersected2.loc[intersected2['ce_id'] != "nan", 'ce'] = 1  # 如果有地役权，标记为1
intersected2 = intersected2[['parcel_id', 'ce']]  # 仅保留地块ID和标记列

# 将保护地役权信息合并到主数据中
alldata = alldata.merge(intersected2, on='parcel_id', how='left')

# 将最终结果保存为GeoPackage文件
alldata.to_file(path + '/merged_carb.gpkg', layer='alldata', driver='GPKG')
