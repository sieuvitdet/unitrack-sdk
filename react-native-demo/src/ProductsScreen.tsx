// Products — plain UI list. No tracking code.
import React from 'react';
import {FlatList, Pressable, Text, StyleSheet} from 'react-native';

const items = [
  {id: 'p-1', name: 'Áo thun Mobix', price: 199000},
  {id: 'p-2', name: 'Bình giữ nhiệt', price: 349000},
  {id: 'p-3', name: 'Tai nghe không dây', price: 899000},
  {id: 'p-4', name: 'Sạc dự phòng', price: 459000},
];

export default function ProductsScreen({navigation}: any) {
  return (
    <FlatList
      style={{backgroundColor: '#fff'}}
      data={items}
      keyExtractor={i => i.id}
      renderItem={({item}) => (
        <Pressable
          testID={`product_row_${item.id}`}
          style={styles.row}
          onPress={() => navigation.navigate('ProductDetail', {product: item})}>
          <Text style={styles.name}>{item.name}</Text>
          <Text style={styles.price}>{item.price.toLocaleString('vi-VN')}đ</Text>
        </Pressable>
      )}
    />
  );
}

const styles = StyleSheet.create({
  row: {padding: 16, borderBottomWidth: 1, borderBottomColor: '#eee'},
  name: {fontSize: 16, fontWeight: '600'},
  price: {color: '#5B8CFF', marginTop: 4},
});
